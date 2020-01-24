(* 
 This file contains most code implementing the loop summarization algorithm
 descried in Automatic Partial Loop Summarization in Dynamic Test Generation
 (ISSTA'11.)
 Our implementation are different with the original paper in several ways:
 - The original algorithm is based on concolic execution, while our 
 implementation is pure symbolic.
*)

module DS = Set.Make (Int64);;
module V = Vine;;

exception LoopsumNotReady

open Exec_options;;
open Frag_simplify;;
open Exec_exceptions;;

(* Split a jmp condition to (lhs, rhs, op)*)
(* b := the in loop side of the cjmp (true/false) *)
(* TODO: add support to more operations*)
let split_cond e b unwrap_temp =
  let rec split e b = 
    (let msg = "Check loop cond" in
       (match e with
          (* je/jne *)
          | V.BinOp(V.EQ, lhs, (V.Constant(_) as rhs)) ->
              (if !opt_trace_loopsum then
                 Printf.eprintf "%s (je/jne):\n%s\n" msg (V.exp_to_string e);
               if b then (Some lhs, Some rhs, V.EQ) else (Some lhs, Some rhs, V.NEQ))
          (* jl/jge*)
          | V.BinOp(V.SLT, (V.BinOp(V.PLUS, _, _) as lhs), (V.Constant(_) as rhs)) ->
              (if !opt_trace_loopsum then
                 Printf.eprintf "%s (jl/jge):\n%s\n" msg (V.exp_to_string e);
               if b then (Some lhs, Some rhs, V.SLT) else (Some rhs, Some lhs, V.SLE))
          (* jg/jle *)
          | V.BinOp(V.BITOR, V.BinOp(V.SLT, _, _), V.BinOp(V.EQ, lhs, rhs))
          | V.BinOp(V.SLE, lhs, rhs) ->
              (if !opt_trace_loopsum then
                 Printf.eprintf "%s (jg/jle):\n%s\n" msg (V.exp_to_string e);
               if b then (Some lhs, Some rhs, V.SLE) else (Some rhs, Some lhs, V.SLT))
          (* js/jns *)
          | V.Cast(V.CAST_HIGH, V.REG_1, V.BinOp(V.PLUS, lhs, rhs)) ->
              (if !opt_trace_loopsum then
                 Printf.eprintf "%s (js/jns):\n%s\n" msg (V.exp_to_string e);
               if b then (Some lhs, Some (V.UnOp(V.NEG, rhs)), V.SLT) 
               else (Some (V.UnOp(V.NEG, rhs)), Some lhs, V.SLE))
          (* jae/jb *)
          | V.BinOp(V.LT, (V.Constant(_) as lhs), rhs)
          | V.BinOp(V.LT, lhs, (V.Constant(_) as rhs)) ->
              (if !opt_trace_loopsum then
                 Printf.eprintf "%s (jae/jb):\n%s\n" msg (V.exp_to_string e);
               if b then (Some lhs, Some rhs, V.LT) else (Some rhs, Some lhs, V.LE))
          (* ja/jbe *)
          | V.BinOp(V.BITOR, V.BinOp(V.LT, _, _), V.BinOp(V.EQ, lhs, rhs)) ->
              (if !opt_trace_loopsum then
                 Printf.eprintf "%s (ja/jbe):\n%s\n" msg (V.exp_to_string e);
               if b then (Some lhs, Some rhs, V.LE) else (Some rhs, Some lhs, V.LT))
          | V.Lval(V.Temp(var)) -> 
              (let e_opt = unwrap_temp var in
                 match e_opt with
                   | Some e -> split e b
                   | None -> (None, None, V.NEQ))
          (* Unwrap temps when they are part of the expression*)
          | V.BinOp(V.LT, V.Lval(V.Temp(var)), c)
          | V.BinOp(V.LT, c, V.Lval(V.Temp(var))) ->
              (let e_opt = unwrap_temp var in
                 match e_opt with
                   | Some e -> split (V.BinOp(V.LT, c, e)) b
                   | None -> (None, None, V.NEQ))
          | V.BinOp(V.BITOR, V.Lval(V.Temp(var)), (V.BinOp(V.EQ, _, _) as cond)) ->
              (let e_opt = unwrap_temp var in
                 match e_opt with
                   | Some e -> split (V.BinOp(V.BITOR, e, cond)) b
                   | None -> (None, None, V.NEQ))
          | V.BinOp(V.BITOR, 
                    V.BinOp(V.SLT,
                            V.BinOp(V.PLUS, V.Lval(V.Temp(var1)), (V.Constant(_) as c1)), 
                            (V.Constant(_) as c2)), 
                    V.Lval(V.Temp(var2))) ->
              (let e1_opt = unwrap_temp var1 
               and e2_opt = unwrap_temp var2 in
                 match (e1_opt, e2_opt) with
                   | (Some e1, Some e2) -> 
                       (split 
                          (V.BinOp(V.BITOR, 
                                   V.BinOp(V.SLT,
                                           V.BinOp(V.PLUS, e1, c1), 
                                           c2), 
                                   e2))
                          b)
                   | _ -> (None, None, V.NEQ))
          | V.Ite(e', _, _) -> (Printf.eprintf "Split ite %s to %s" (V.exp_to_string e) (V.exp_to_string e'); split e' b)
          (* Ignore this expr if it's True or False *)
          | V.Constant(V.Int(V.REG_1, b)) -> 
              (Printf.eprintf "%s %Ld\n" msg b;
                (None, None, V.NEQ))
          | _ -> 
              Printf.eprintf "split_cond currently doesn't support this condition(%B): %s\n" b (V.exp_to_string e);
              (None, None, V.NEQ)
       ))
  in
    split e (not b)


let print_set set = 
  Printf.eprintf "Set = {";
  DS.iter (fun d -> Printf.eprintf "0x%08Lx, " d) set;
  Printf.eprintf "}\n"

(* Minimum negative value*)    
(* MINUS 1 to get max positive value*)
let min_signed ty =
  match ty with
    | V.REG_1 -> (0x1L)
    | V.REG_8 -> (0x80L)
    | V.REG_16 -> (0x8000L)
    | V.REG_32 -> (0x80000000L)
    | V.REG_64 -> (0x8000000000000000L)
    | _  -> failwith "Illegal type\n" 

let max_unsigned ty = 
  match ty with
    | V.REG_1 -> (0x1L)
    | V.REG_8 -> (0xffL)
    | V.REG_16 -> (0xffffL)
    | V.REG_32 -> (0xffffffffL)
    | V.REG_64 -> (0xffffffffffffffffL)
    | _  -> failwith "Illegal type\n" 

(* Compute the Greatest Common Divisor using Extended Euclidean Algorithm *)
(* ax + by = gcd(a, b), return (x, y, gcd(a, b))*)
let rec gcd_extend a b  =
  if a = 0L then (0L, 1L, b)
  else
    let (x, y, gcd) = gcd_extend (Vine_util.int64_urem b a) a in
    let x' = Int64.sub y (Int64.mul (Int64.div b a) x) in
    let y' = x in
      (x', y', gcd)

(* Compute the modular inverse of `a` under modulo m *)
(* if a and m are not coprime, return 0 *)
let mod_inverse a m =
  if m = 0L then 0L
  else
    let (x, y, gcd) = gcd_extend a m in
      if gcd = 1L then
        Vine_util.int64_urem (Int64.add (Vine_util.int64_urem x m) m) m
      else 0L

(* right shift d until the least significant bit is 1 *)
(* d = d'*(2^j), return d' and j*)
let split_to_prime d = 
  let d' = ref d in
  let j = ref 0 in
    while (Vine_util.int64_urem !d' 2L) = 0L do
      d' := Int64.shift_right_logical !d' 1;
      j := !j + 1
    done;
    (!d', !j)

class simple_node id = object(self)
  val mutable domin = DS.singleton id
  val mutable domin_snap = DS.singleton id

  method add_domin dom = domin <- (DS.add dom domin)

  method get_domin = domin 

  method set_domin domin' = domin <- domin'

  method update_domin update = domin <- DS.union domin update

  method make_snap = 
    domin_snap <- DS.empty;
    DS.iter (fun d -> domin_snap <- DS.add d domin_snap) domin

  method reset_snap = 
    domin <- DS.empty;
    DS.iter (fun d -> domin <- DS.add d domin) domin_snap
end

(*Simple graph that contains some basic operations and automatic dominator computation*)
class simple_graph (h: int64) = object(self)
  val head = h
  val mutable nodes = Hashtbl.create 100
  val successor = Hashtbl.create 100
  val predecessor = Hashtbl.create 100

  (*NOTE: what's the purpose to have domin and full_domin?*)
  val mutable domin = DS.empty
  val mutable full_dom = DS.empty

  method private dom_size dom = 
    let s = DS.cardinal dom in
      (*Printf.eprintf "dom size: %d\n" s;*)
      s

  method private eip_to_node eip = try Hashtbl.find nodes eip with Not_found -> None

  method private eip_to_set eip = 
    let node = self#eip_to_node eip in
      match node with
        | None -> DS.empty
        | Some n -> n#get_domin

  (* Compute dominators set*)
  method dom_comp id = 
    domin <- full_dom;
    let inter_set pred_id set = 
      let pred_set = self#eip_to_set pred_id in
        DS.inter pred_set set;
    in
    let pred_id_list = self#pred id in
      List.iter (fun pid -> domin <- inter_set pid domin) pred_id_list;
      domin <- DS.add id domin; 
      let node = self#eip_to_node id in
        (match node with 
          | Some n -> n#update_domin domin
          | None -> ());
        domin <- DS.empty

  method add_node id = 
    let node = new simple_node id in
      Hashtbl.replace nodes id (Some node);
      full_dom <- DS.add id full_dom;
      if !opt_trace_loop_detailed then
        Printf.eprintf "Add %Lx to graph %Lx\n" id head

  method add_edge tail head =
    let add_nodup tbl a b =
      let l = Hashtbl.find_all tbl a in
        if not (List.mem b l) then Hashtbl.add tbl a b
    in
    if not (Hashtbl.mem nodes tail) then 
      self#add_node tail;
    add_nodup successor tail head;
    add_nodup predecessor head tail;
    if not (Hashtbl.mem nodes head) then 
      (self#add_node head;
       self#dom_comp head)
    else
      self#dom_comp head
(*       Printf.eprintf "Node 0x%Lx already in list, don't compute dom\n" head *)

  method pred n = 
    Hashtbl.find_all predecessor n

  (*return whether d dominate x*)
  method is_dom x d = 
    let dom = self#eip_to_set x in
    let res = DS.mem d dom in
      if !opt_trace_loop_detailed then
        if res = true then Printf.eprintf "0x%08Lx dominate 0x%08Lx\n" d x
        else Printf.eprintf "0x%08Lx does not dominate 0x%08Lx\n" d x;
      res

  method reset =
    domin <- DS.empty;
    let reset_node e n = 
      match n with
        | Some node -> node#set_domin DS.empty
        | None -> ()
    in
      Hashtbl.iter reset_node nodes;

  method make_snap =
    Hashtbl.iter (fun _ n -> 
                    match n with
                      | Some node -> node#make_snap
                      | None -> ()
    ) nodes

  method reset_snap =
    let reset_node e n = 
      match n with
        | Some node -> node#reset_snap
        | None -> ()
    in
      Hashtbl.iter reset_node nodes;

end

class loop_record tail head g= object(self)
  val mutable iter = 1
  val mutable iter_snap = 1
  (* A loop record is identified by the dest of the backedge *)
  val id = head
  val loop_body = Hashtbl.create 100

  (* loopsum set (lss) = (ivt, gt, bdt, geip)*)
  (* geip := the guard to leave from*)
  (* bdt := in-loop branch decision *)
  val mutable lss = []

  method get_lss = lss

  method set_lss s = lss <- s

  (* List of in-loop branch conditions and the associated prog slices *)
  (* This list is shared among all summaries in the same lss*)
  (* bt := (eip -> (cond, slice))*)
  val bt = Hashtbl.create 10

  (* List of in-loop branch decisions made in current Path *)
  (* each bdt is associated with one loopsum *)
  (* bdt := (eip -> decision(bool))*)
  val mutable bdt = Hashtbl.create 10
  val mutable snap_bdt = Hashtbl.create 10

  method private bdt_cmp bdt bdt' = 
    if not (Hashtbl.length bdt == Hashtbl.length bdt') then false
    else
      let res = ref true in
        Hashtbl.iter (fun (eip:int64) d ->
                        match (Hashtbl.find_opt bdt' eip) with
                          | Some d' -> if not d = d' then res := false
                          | None -> res := false
        ) bdt;
        !res

  method add_bd eip b =
    Hashtbl.replace bdt eip b

  method add_slice (eip:int64) (cond: V.exp) (slice: V.stmt list) = 
    Hashtbl.replace bt eip (cond, slice)

  method find_slice eip = 
    match (Hashtbl.find_opt bt eip) with
      | Some s -> true
      | None -> false

  (* Status about applying loopsum*)
  (* None: haven't tried to apply loopsum *)
  (* Some false : has checked this loop but no feasible loopsum, either *) 
  (*              because non of them work for current path or there is *)
  (*              no loopsum*)
  (* Some true : a loopsum has been applied to this loop*)
  val mutable loopsum_status = None
  val mutable loopsum_status_snap = None
                              
  method get_status = loopsum_status
 
  method set_status opt = (
    if !opt_trace_loopsum_detailed then
      Printf.eprintf "set use_loopsum to %s\n" 
        (match opt with
           | Some b -> Printf.sprintf "%B" b
           | None -> "None");
    loopsum_status <- opt)

  method update_loopsum = 
    loopsum_status <- None

  method inc_iter = 
    iter <- (iter + 1);
    if !opt_trace_loop then (
      Printf.eprintf "----------------------------------------------------------------------------\n";
      Printf.eprintf "iter [+1] : %d\n" iter)

  method get_iter = iter

  (* Inductive variable table (IVT) = (offset, V_0, V, V', dV)*)
  (* offset:= addr offset from stack pointer *)
  (* NOTE: add ty to this table instead of intering it on demand?*)
  val mutable ivt = []
  val iv_cond_t = Hashtbl.create 10

  (* Return true if ivt and ivt' are identical *)
  (* For the IVTs of the same loopsum, there should be exactly the same number*)
  (* of IVs, added in exactly the same order*)
  method private ivt_cmp ivt ivt' =
    if not (List.length ivt = List.length ivt') then false
    else
      let res = ref true in
        List.iteri (fun i iv ->
                      let (off, _, _, _, dv) = iv
                      and (off', _, _, _, dv') = List.nth ivt' i in
                        if not (off = off' && dv = dv') then res := false
        ) ivt;
        !res

  method private ivt_search off = 
    let res = ref None in
    let loop ((offset, v0, v, v', dv_opt) as iv) = (
      if off = offset then res := Some iv
    ) in 
      List.iter loop ivt;
      !res

  method is_iv_cond cond = 
    let res = Hashtbl.mem iv_cond_t cond in
      res

  (* At the end of each loop iteration, check each iv and clean ivt if *)
  (* - any iv is changed by a different dV from previous, OR*)
  (* - any iv is not changed in current iter *)      
  method update_ivt simplify check =
    let simplify_cond exp = 
      (let rec is_cond e = 
         (match e with
            | V.BinOp(op, exp1, exp2) -> 
                (match op with                
                   | (V.EQ | V.NEQ | V.SLT | V.SLE | V.LT | V.LE) -> true
                   | _ -> ((is_cond exp1)&&(is_cond exp2)))
            | _ -> (false)) 
       in
         if is_cond exp then simplify V.REG_1 exp else exp)
    in
    let simplify_typecheck exp =
      let typ = Vine_typecheck.infer_type_fast exp in
        simplify typ exp
    in
    let rec check_ivt l =
      match l with
        | iv::l' ->
            (let (offset, v0, v, v', dv_opt) = iv in
               if iter = 2 then (offset, v0, v', v', dv_opt)::(check_ivt l')
               else if check (V.BinOp(V.EQ, v', v)) then check_ivt l'
               else
                 let dv' = simplify_typecheck (V.BinOp(V.MINUS, v', v)) in
                   match dv_opt with
                     | None -> 
                         (offset, simplify_typecheck (V.BinOp(V.MINUS, v0, dv')), v', v', Some dv')::(check_ivt l')
                     | Some dv -> 
                         (*NOTE: should check validity instead of satisfiability?*)
                         (let cond = V.BinOp(V.EQ, dv, dv') in
                            (match (simplify_cond cond) with
                               | V.Constant(V.Int(V.REG_1, 1L)) -> 
                                   (offset, v0, v', v', Some dv')::(check_ivt l')
                               | V.Constant(V.Int(V.REG_1, 0L)) -> check_ivt l'
                               | _ ->
                                   (if check cond then
                                      (Hashtbl.replace iv_cond_t cond ();
                                       (offset, v0, v', v', Some dv')::(check_ivt l'))
                                    else check_ivt l'))))
        | [] -> []
    in
    let ivt' = check_ivt ivt in
      if (List.length ivt') < (List.length ivt) then ivt <- []
      else ivt <- ivt'

  method get_ivt = ivt

  method in_loop eip = 
    let res = Hashtbl.mem loop_body eip in
      if !opt_trace_loop_detailed then
        (match res with
           | true -> (Printf.eprintf "0x%08Lx is in the loop <0x%08Lx>\n" eip id)
           | false  -> (Printf.eprintf "0x%08Lx is not in the loop <0x%08Lx>\n" eip id));
      res


  (* FIXME: consider the situation that a variable is updated mutiple times in the same loop iteration*)
  method add_iv (offset: int64) (exp: V.exp) =
    let replace_iv (offset, v0, v, v', dv) = 
      (let rec loop l =
         (match l with
            | iv::l' -> (
                let (offset', _, _, _, _) = iv in
                  if offset' = offset then [(offset, v0, v, v', dv)] @ l' 
                  else [iv] @ (loop l'))
            | [] -> [])
       in
         ivt <- loop ivt)
    in
    match (self#ivt_search offset) with
      | Some iv -> 
          let (offset, v0, v, v', dv) = iv in
            if not (v' = exp) then replace_iv (offset, v0, v, exp, dv)
      | None -> 
          if iter = 2 then 
            (Printf.eprintf "Add new iv with offset = %Lx\n" offset;
             ivt <- ivt @ [(offset, exp, exp, exp, None)])

  (*Guard table: (eip, op, ty, D0_e, slice, D, dD, b, exit_eip)*)
  (*D0_e: the code exp of the jump condition's location*)
  (*D: the actual distance of current iteration, updated at each new occurence of the same loop*)
  (*EC: the expected execution count*)
  (*b: denotes which side of the cjmp branch is in the loop*)
  val mutable gt = []

  method private gt_cmp gt gt' =
    if not (List.length gt = List.length gt') then false
    else
      let res = ref true in
        List.iteri (fun i g ->
                      let (eip, _, _, _, _, _, _, _, _) = g 
                      and (eip', _, _, _, _, _, _, _, _) = List.nth gt' i in
                        if not (eip = eip') then res := false
        ) gt;
        !res

  (* Given an eip, check whether it is the eip of an existing guard *)
  method is_known_guard geip gt = 
    let res = ref None in
      List.iter (fun ((eip, _, _, _, _, _, _, _, _) as g) ->
                   if eip = geip then res := Some g
      ) gt;
      !res

  (* Formulas to compute EC (expected count)*)
  (* EC = (D+dD+1)/dD if integer overflow not happen *)
  (* EC = (D-1)/dD + 1 if iof happens*)
  (* D is unsigned and dD should be positive *)
  method private ec var = 
    let (op, ty, d, dd) = var in
      V.Ite(V.BinOp(V.LT, V.BinOp(V.PLUS, d, dd), d),
            V.BinOp(V.PLUS, 
                    V.BinOp(V.DIVIDE, 
                            V.BinOp(V.MINUS, d, V.Constant(V.Int(ty, 1L))), 
                            dd),
                    V.Constant(V.Int(ty, 1L))),
            V.BinOp(V.DIVIDE, 
                    V.BinOp(V.MINUS, 
                            V.BinOp(V.PLUS, d, dd), 
                            V.Constant(V.Int(ty, 1L))), dd))

  (* Compute expected loop count from a certain guard*)
  (* D and dD should not be 0, otherwise current path never enter/exit the loop *)
  method private compute_ec (_, op, ty, d0_e, slice, _, dd_opt, b, _) 
          check eval_cond simplify unwrap_temp query_unique_value run_slice =
    run_slice slice;
    let e = eval_cond d0_e in
    match (split_cond e b unwrap_temp) with
    | (Some lhs, Some rhs, _) ->
        (* Check integer overflow by checking whether D and dD are both *)
        (* positive/negative, and compute EC with modified D and dD accordingly*)
        (let d_opt = self#compute_distance op ty lhs rhs simplify in
         let d = 
           (match d_opt with
              | Some d -> assert(check (V.BinOp(V.NEQ, V.Constant(V.Int(ty, 0L)), d))); d
              | None -> failwith "Unsupported comparison") in
         let dd = 
           (match dd_opt with
              | Some dd -> assert(check (V.BinOp(V.NEQ, V.Constant(V.Int(ty, 0L)), dd))); dd
              | None -> failwith "No dD") in
         let d_cond = V.BinOp(V.SLT, V.Constant(V.Int(ty, 0L)), d) in
         let dd_cond = V.BinOp(V.SLT, V.Constant(V.Int(ty, 0L)), dd) in
           (match op with
              | V.SLE | V.SLT ->
                  Some
                    (V.Ite(V.BinOp(V.XOR, d_cond, dd_cond),
                           self#ec (op, ty, 
                                    V.Ite(d_cond, d, V.UnOp(V.NOT, d)), 
                                    V.Ite(dd_cond, dd, V.UnOp(V.NEG, dd))),
                           V.Ite(V.BinOp(V.BITAND, d_cond, dd_cond),
                                 self#ec (op, ty, 
                                          V.BinOp(V.PLUS, 
                                                  V.BinOp(V.MINUS, 
                                                          V.Constant(V.Int(ty, Int64.sub (min_signed ty) 1L)), 
                                                          lhs), dd), dd),
                                 self#ec (op, ty, 
                                          V.BinOp(V.MINUS, 
                                                  V.BinOp(V.MINUS, 
                                                          V.Constant(V.Int(ty, min_signed ty)), lhs), dd), 
                                          V.UnOp(V.NEG, dd)))))
              | V.LE | V.LT ->
                  Some
                    (V.Ite(V.BinOp(V.XOR, d_cond, dd_cond),
                           self#ec (op, ty, 
                                    V.Ite(d_cond, d, V.UnOp(V.NEG, dd)),
                                    V.Ite(dd_cond, dd, V.UnOp(V.NEG, dd))),
                           V.Ite(V.BinOp(V.BITAND, d_cond, dd_cond),
                                 self#ec (op, ty, V.BinOp(V.PLUS, 
                                                          V.BinOp(V.MINUS, 
                                                                  V.Constant(V.Int(ty, max_unsigned ty)), 
                                                                  lhs), dd), dd),
                                 self#ec (op, ty, V.BinOp(V.MINUS, lhs, dd), dd))))
              | V.EQ ->
                  (let reachable = 
                     V.BinOp(V.EQ, 
                             V.BinOp(V.MOD, 
                                     V.Ite(d_cond, d, V.UnOp(V.NEG, d)), 
                                     V.Ite(dd_cond, dd, V.UnOp(V.NEG, dd))), 
                             V.Constant(V.Int(ty, 0L)))
                   in
                   let no_iof = V.BinOp(V.XOR, d_cond, dd_cond) in
                     match (check no_iof, check reachable) with
                       | (true, true) ->
                           Some 
                             (self#ec (op, ty, 
                                       V.Ite(d_cond, d, V.UnOp(V.NEG, dd)),
                                       V.Ite(dd_cond, dd, V.UnOp(V.NEG, dd))))
                       | (true, false) -> None
                       | (false, _) ->
                           (match (query_unique_value dd ty) with
                              | Some dd_conc ->
                                  (let m = 
                                     (match ty with
                                        | V.REG_64 -> 0L
                                        | _ -> Int64.add (max_unsigned ty) 1L)
                                   in
                                   let inverse = mod_inverse dd_conc m in
                                     if inverse = 0L then
                                       (let (dd_conc', j) = split_to_prime dd_conc in
                                        let mask = 
                                          Int64.shift_right_logical 
                                            (max_unsigned ty) 
                                            ((V.bits_of_width ty) - j)
                                        in
                                        let d_hi = V.BinOp(V.BITAND, d, 
                                                           V.Constant(V.Int(ty, mask)))
                                        in
                                          match (query_unique_value d_hi ty) with 
                                            | Some d_conc' -> 
                                                Some (V.BinOp(V.TIMES, 
                                                              V.Constant(V.Int(ty, dd_conc')),
                                                              V.BinOp(V.RSHIFT, d, 
                                                                      V.Constant(V.Int(ty, Int64.of_int j)))))
                                            | None -> None)
                                     else 
                                       Some (V.BinOp(V.TIMES, d, 
                                                     V.Constant(V.Int(ty, inverse)))))
                              | None -> None))
(*
                        V.Ite(V.BinOp(V.BITAND, d_cond, dd_cond),
                               self#ec (op, ty, V.BinOp(V.MINUS, rhs, lhs), dd),
                               self#ec (op, ty, d, V.UnOp(V.NEG, dd)))
 *)
              | _ -> failwith "invalid guard operation"))
    | _ -> 
        (Printf.eprintf "Unable to split %s\n" (V.exp_to_string e);
         raise Not_found)

  (* Given lhs, rhs and op, compute a distance (D)*)
  (* loop_cond := if true, stay in the loop*) 
  (* iof_cond = lhs>0 && rhs<0 && lhs-rhs<lhs; if true, integer overflow happens*)
  (* when computing D*)
  (* TODO: handle IOF*)
  method private compute_distance op ty lhs rhs simplify =
    let msg = ref "" in
    let res = 
      (match op with
         | V.SLE -> 
             (let loop_cond = V.BinOp(V.SLT, rhs, lhs) in
              let iof_cond = 
                V.BinOp(V.BITAND, 
                        V.BinOp(V.BITAND, 
                                V.BinOp(V.SLT, rhs, V.Constant(V.Int(ty, 0L))), 
                                V.BinOp(V.SLT, V.Constant(V.Int(ty, 0L)), lhs)), 
                        V.BinOp(V.SLT, V.BinOp(V.MINUS, lhs, rhs), lhs)) 
              in 
                msg := !msg ^ (Printf.sprintf "loop_cond %s\n" (V.exp_to_string (simplify V.REG_1 loop_cond)));
                msg := !msg ^ (Printf.sprintf "iof_cond %s\n" (V.exp_to_string (simplify V.REG_1 iof_cond)));
                Some (V.Ite(V.BinOp(V.BITAND, loop_cond, V.UnOp(V.NOT, iof_cond)),
                           V.BinOp(V.MINUS, lhs, rhs),
                           V.Constant(V.Int(ty, 0L)))))
         | V.SLT -> 
             (let loop_cond = V.BinOp(V.SLE, rhs, lhs) in
              let iof_cond = 
                V.BinOp(V.BITAND, 
                        V.BinOp(V.BITAND, 
                                V.BinOp(V.SLT, rhs, V.Constant(V.Int(ty, 0L))), 
                                V.BinOp(V.SLT, V.Constant(V.Int(ty, 0L)), lhs)), 
                        V.BinOp(V.SLT, V.BinOp(V.MINUS, lhs, rhs), lhs)) 
              in 
                msg := !msg ^ (Printf.sprintf "loop_cond %s\n" (V.exp_to_string (simplify V.REG_1 loop_cond)));
                msg := !msg ^ (Printf.sprintf "iof_cond %s\n" (V.exp_to_string (simplify V.REG_1 iof_cond)));
                Some (V.Ite(V.BinOp(V.BITAND, loop_cond, V.UnOp(V.NOT, iof_cond)),
                           V.BinOp(V.MINUS, lhs, rhs),
                           V.Constant(V.Int(ty, 0L)))))
         | V.LE -> 
             (let cond = V.BinOp(V.LT, rhs, lhs) in
                Some (V.Ite(cond, V.BinOp(V.MINUS, lhs, rhs), V.Constant(V.Int(ty, 0L)))))
         | V.LT -> 
             (let cond = V.BinOp(V.LE, rhs, lhs) in
                Some (V.Ite(cond, V.BinOp(V.MINUS, lhs, rhs), V.Constant(V.Int(ty, 0L)))))
         | V.EQ -> 
             (Some (V.BinOp(V.MINUS, lhs, rhs)))
         | _  -> None)
    in
      if !opt_trace_loopsum_detailed then Printf.eprintf "%s" !msg;
      res

  method private branch_to_guard l g =
    let (eip, _, _, _, _, _, _, _, _) = g in
    Printf.eprintf "branch_to_guard at %Lx\n" eip;
    let lss' = 
      List.map (fun ls ->
                   let (ivt, gt, bdt, geip) = ls in
                     match (Hashtbl.find_opt bdt eip) with
                       | Some bd -> 
                           (let gt' = gt @ [g] in
                              Hashtbl.remove bdt eip;
                              (ivt, gt', bdt, geip))
                       | None -> ls
      ) l in
      lss <- lss'

  (* Add or update a guard table entry*)
  method add_g g' check simplify =
    let (eip, op, ty, d0_e, (slice: V.stmt list), lhs, rhs, b, eeip) = g' in
      if !opt_trace_loopsum_detailed then
        Printf.eprintf "At iter %d, check cjmp at %08Lx, op = %s\n" iter eip (V.binop_to_string op);
      (match self#is_known_guard eip gt with
         | Some g -> 
             (let (_, _, _, _, _, d_opt, dd_opt, _, _) = g in
              let d_opt' = self#compute_distance op ty lhs rhs simplify in
                (match (d_opt, d_opt', dd_opt) with
                   | (Some d, Some d', None) ->
                       (let dd' = V.BinOp(V.MINUS, d', d) in
                          self#replace_g (eip, op, ty, d0_e, slice, Some d', Some dd', b, eip))
                   | (Some d, Some d', Some dd) ->
                       (let dd' = V.BinOp(V.MINUS, d', d) in
                          if check (V.BinOp(V.EQ, dd, dd')) then
                            self#replace_g (eip, op, ty, d0_e, slice, Some d', Some dd', b, eip)
                          else Printf.eprintf "Guard at 0x%Lx not inductive\n" eip)
                   | _ -> ()))
         | None -> 
             (if iter = 2 then
                (let d_opt = self#compute_distance op ty lhs rhs simplify in
                 let g = (eip, op, ty, d0_e, slice, d_opt, None, b, eeip) in
                   match d_opt with
                     | Some d ->
                         (gt <- gt @ [g];
                          match (Hashtbl.find_opt bt eip) with
                            | Some branch -> 
                                (Hashtbl.remove bt eip;
                                 self#branch_to_guard lss g)
                            | None -> (Printf.eprintf "add_g: no bt entry associated with %Lx\n" eip);
                          if !opt_trace_loopsum_detailed then                     
                            Printf.eprintf "add_g: add new guard at 0x%08Lx, D0 =  %s\n" eip (V.exp_to_string d))
                     | None ->
                         (* Currently not sure whether this CJmp is a Guard or in-loop branch *)
                         (* Add it as a branch now and remove later if it is a Guard *)
                         (Printf.eprintf "add_g: fail to compute D0 at %Lx, still add it to bt and bdt\n" eip;
                          self#add_slice eip d0_e slice;
                          self#add_bd eip b))))

  method private print_ivt ivt = 
    Printf.eprintf "* Inductive Variables Table [%d]\n" (List.length ivt);
    List.iteri (fun i (offset, v0, v, v', dv) ->
                  Printf.eprintf "[%d]\tmem[sp+%Lx] = %s " i offset (V.exp_to_string v0);
                  match dv with
                    | Some d -> Printf.eprintf "\t(+ %s)\n" (V.exp_to_string d)
                    | None -> Printf.eprintf "\t [dV N/A]\n"
    ) ivt

  method private print_gt gt =
    Printf.eprintf "* Guard Table [%d]\n" (List.length gt);
    List.iteri (fun i (eip, _, _, d0_e, _,  _, _, _, eeip) ->
                  Printf.eprintf "[%d]\t0x%Lx\t%s\t0x%Lx\n" i eip (V.exp_to_string d0_e) eeip
    ) gt

  method private print_bdt bdt = 
    Printf.eprintf "* Branch Decisions[%d]:\n" (Hashtbl.length bdt);
    Hashtbl.iter (fun eip b ->
                    Printf.eprintf "0x%Lx\t%B\n" eip b
    ) bdt

  method get_gt = gt

  method private replace_g g' = 
    let rec loop l =
      match l with
        | g::l' -> (
            let (e, _, _, _, _, _, _, _, _) = g in
            let (eip, _, _, _, _, _, _, _, _) = g' in
              if e = eip then [g'] @ l'
              else[g] @ (loop l'))
        | [] -> []
    in
      gt <- loop gt

  method get_head = id

  method add_insn (eip:int64) = 
    Hashtbl.replace loop_body eip ()

  (* Return true if new loopsum n already exist in lss *)
  method private check_dup_lss n = 
    let rec check_dup l n = 
      (match l with
         | h::rest ->
             (let (ivt, gt, bdt, geip) = h
              and (ivt', gt', bdt', geip') = n in
                if (geip = geip' 
                    && (self#bdt_cmp bdt bdt')
                    && (self#ivt_cmp ivt ivt') 
                    && (self#gt_cmp gt gt')) 
                then true
                else check_dup rest n)
         | [] -> false)
    in
      check_dup lss n

  method private print_lss =
    Printf.eprintf "lss length %d\n" (List.length lss);
    List.iteri (fun i (ivt, gt, bdt, geip) ->
                  Printf.eprintf "lss[%d]:\n" i;
                  self#print_ivt ivt;
                  self#print_gt gt;
                  self#print_bdt bdt;
                  Printf.eprintf "Leave from 0x%Lx\n" geip
    ) lss

  (* Save current (ivt, gt, bdt, geip) to a new lss if valid*)
  (* Call this function when exiting a loop *)
  (* TODO: should also check invalid GT ?*)
  method save_lss geip =
    if (self#is_known_guard geip gt) = None then
      Printf.eprintf "No lss saved since %Lx is not a guard\n" geip
    else
      let all_valid = ref true in
        List.iter (fun iv ->
                     let (_, _, _, _, dv) = iv in
                       if dv = None then all_valid := false 
        ) ivt;
        if not !all_valid then
          Printf.eprintf "No lss saved since some IV invalid\n"
        else if (self#check_dup_lss (ivt, gt, bdt, geip)) then 
          Printf.eprintf "lss already exist, ignore\n"
        else
          lss <- lss @ [(ivt, gt, Hashtbl.copy bdt, geip)];
        self#print_lss

  method private compute_precond loopsum check eval_cond simplify unwrap_temp 
          query_unique_value (run_slice: V.stmt list -> unit) =
    let (_, gt, bdt, geip) = loopsum in
    let min_g_opt = self#is_known_guard geip gt in 
      match min_g_opt with
        | Some min_g ->
            (* Construct the condition that Guard_i is the one with minimum EC*)
            (let min_ec_opt = 
               self#compute_ec min_g check eval_cond simplify unwrap_temp query_unique_value run_slice 
             in
             let min_ec_cond geip gt =
               let res = ref (V.Constant(V.Int(V.REG_1, 1L))) in
               let after_min = ref false in
                 (match min_ec_opt with
                    | Some min_ec ->
                        List.iter 
                          (fun g ->
                             let (eip, _, _, _, _, _, _, _, _) = g in
                               if not (eip = geip) then
                                 (match (self#compute_ec g check eval_cond simplify 
                                           unwrap_temp query_unique_value run_slice) with
                                    | Some ec -> 
                                        if !after_min then
                                          res := V.BinOp(V.BITAND, !res, V.BinOp(V.SLE, min_ec, ec))
                                        else
                                          res := V.BinOp(V.BITAND, !res, V.BinOp(V.SLT, min_ec, ec))
                                    | None -> ())
                               else after_min := true
                          ) gt
                    | None -> res := (V.Constant(V.Int(V.REG_1, 0L))));
                 Printf.eprintf "min_ec_cond = %s\n" (V.exp_to_string (simplify V.REG_1 !res));
                 !res
             in
             let branch_cond bdt =                
               (let res = ref (V.Constant(V.Int(V.REG_1, 1L))) in
                  Hashtbl.iter (fun eip d ->
                                  match Hashtbl.find_opt bt eip with
                                    | Some (cond, slice) -> 
                                        (run_slice slice;
                                         if d then 
                                           res := V.BinOp(V.BITAND, !res, eval_cond cond)
                                         else res := V.BinOp(V.BITAND, !res, eval_cond (V.UnOp(V.NOT, cond))))
                                    | None -> ()
                  ) bdt;
                  !res)
             in
               (* Run the prog slice of each in-loop branch and eval*)
               Printf.eprintf "branch_cond: %s\n" (V.exp_to_string (branch_cond bdt));
               V.BinOp(V.BITAND, (branch_cond bdt), (min_ec_cond geip gt)))
        | _ -> failwith ""

  method compute_loop_body tail head (g:simple_graph) = 
    let rec inc_loopbody eip = 
      if not (eip = head) then 
        (self#add_insn eip;
         let pred = g#pred eip in
           if !opt_trace_loop_detailed then
             (Printf.eprintf "pred %Lx { " eip;
              List.iter (fun addr ->
                           Printf.eprintf "%Lx, " addr) pred;
              Printf.eprintf "}\n");
           List.iter inc_loopbody pred)
    in
      inc_loopbody tail;
      self#add_insn tail;
      self#add_insn head;
      if !opt_trace_loop then
        (Printf.eprintf "Compute loopbody (%Lx -> %Lx) size: %d\n" 
           tail head (Hashtbl.length loop_body);
         let msg = ref "" in
           Hashtbl.iter (fun eip _ ->
                           msg := !msg ^ (Printf.sprintf "%Lx " eip)
           ) loop_body;
           Printf.eprintf "{%s}\n" !msg)

  (* Check whether any existing loop summarization that can fit current
   condition and return the updated values and addrs of IVs.
   NOTE: the update itself implemented in sym_region_frag_machine.ml*)
  (*TODO: loopsum preconds should be add to path cond*)
  method check_loopsum eip check (add_pc: V.exp -> unit) simplify load_iv eval_cond unwrap_temp
          try_ext (random_bit:bool) (is_all_seen: int -> bool) query_unique_value
          (cur_ident: int) get_t_child get_f_child (add_node: int -> unit) run_slice = 
    let trans_func (_ : bool) = V.Unknown("unused") in
    let try_func (_ : bool) (_ : V.exp) = true in
    let non_try_func (_ : bool) = () in
    let both_fail_func (b : bool) = b in
    let true_bit () = true in
    let false_bit () = false in
    let get_feasible l =
      let feasibles = ref [] in
      let rec check_node id l conds = 
        Printf.eprintf "conds[%d]:%s\n" id (V.exp_to_string (simplify V.REG_1 conds));
        (match l with
           | h::rest ->
               (let (ivt, gt, bdt, geip) = h in
                let precond = self#compute_precond h check eval_cond simplify unwrap_temp 
                                query_unique_value run_slice in
                  Printf.eprintf "Precond[%d]: %s\n" id (V.exp_to_string (simplify V.REG_1 precond));
                  if check (V.BinOp(V.BITAND, precond, conds)) then
                    (Printf.eprintf "lss[%d] is feasible\n" id;
                     feasibles := (V.BinOp(V.BITAND, precond, conds), 
                                   id, ivt, gt, bdt, geip)::!feasibles)
                  else Printf.eprintf "lss[%d] is infeasible\n" id;
                  check_node (id+1) rest (V.BinOp(V.BITAND, conds, V.UnOp(V.NOT, precond))))
           | [] -> ())
      in
        check_node 0 l (V.Constant(V.Int(V.REG_1, 1L)));
        List.rev !feasibles
    in
    let rec get_precond l cur =
      match l with
        | h::rest -> 
            (if cur = -1 || not (is_all_seen (get_t_child cur)) then
               let (_, _, ivt, gt, bdt, geip) = h in
               let loopsum = (ivt, gt, bdt, geip) in
               let precond = self#compute_precond loopsum check eval_cond simplify 
                               unwrap_temp query_unique_value run_slice in
                 V.BinOp(V.BITOR, precond, (get_precond rest (get_f_child cur)))
             else 
               get_precond rest (get_f_child cur)
            ) 
        | [] -> V.Constant(V.Int(V.REG_1, 0L))
    in
    let use_loopsum l =
      (add_node cur_ident;
       let cond = 
         (try 
            get_precond l (get_t_child cur_ident)
          with
            | Not_found -> V.Constant(V.Int(V.REG_1, 0L)))
       in
       let b = check cond in
         (* TODO: enable random decision and add cond to PC (only when no loopsum?) *)
         Printf.eprintf "precond: %s\n" (V.exp_to_string cond);
         if b then 
           (let b =  try_ext trans_func try_func non_try_func true_bit both_fail_func 0x0 in
              if not b then failwith "Inconsist try_extend result: true -> false\n";
              Printf.eprintf "Decide to use loopsum (%B)\n" b)
         else 
           (let b = try_ext trans_func try_func non_try_func false_bit both_fail_func 0x0 in
              if b then failwith "Inconsist try_extend result: false -> true\n";
              Printf.eprintf "Decide not to use loopsum (%B)\n" b);
         b)
    in
    let compute_iv_update loopsum = 
      let (ivt, gt, geip) = loopsum in
      let g_opt = self#is_known_guard geip gt in
        match g_opt with
          | None -> failwith ""
          | Some g ->
              (let (_, _, _, _, _, _, _, _, eeip) = g in
               let ec_opt = self#compute_ec g check eval_cond simplify unwrap_temp 
                              query_unique_value run_slice in 
               let vt = 
                 (match ec_opt with
                    | Some ec ->
                        (List.map 
                           (fun (offset, v, _, _, dv_opt) ->
                              let ty = Vine_typecheck.infer_type_fast v in
                              let v0 = load_iv offset ty in
                                match dv_opt with
                                  | Some dv -> 
                                      (offset, simplify ty (V.BinOp(V.PLUS, v0, V.BinOp(V.TIMES, ec, dv))))
                                  | None -> failwith ""
                           ) ivt) 
                    | None -> [])
               in 
                 (vt, eeip))
    in
    let extend_with_loopsum_dry l id cur =
      Printf.eprintf "Check whether %d(parent %d) is all_seen\n" (get_t_child cur) cur;
      let rec extend l level cur =
        if cur = -1 then true
        else
          (match l with
             | h::rest ->
                 (if level < id then extend rest (level + 1) (get_f_child cur)
                  else if level = id then
                    (let b = (is_all_seen (get_t_child cur)) in
                       not b
                    )
                  else failwith (Printf.sprintf "Cannot find LS[%d]\n" id))
             | _ -> true)
      in
        extend l 1 cur
    in
    let choose_loopsum feasibles =
      let all = List.length feasibles in
      let n = ref (Random.int all) in
        Printf.eprintf "feasible lss = %d\n" all;
        if all <= 0 then failwith "Inconsistency between use_loopsum and choose_loopsum\n";
        while not (extend_with_loopsum_dry feasibles (!n+1) (get_t_child cur_ident)) do
          Printf.eprintf "\tRand = %d\n" !n;
          n := Random.int all
        done;
        let (loopsum_cond, id, ivt, gt, _, geip) = (List.nth feasibles !n) in
        let (vt, eeip) = compute_iv_update (ivt, gt, geip) in
          (!n, id, vt, eeip)
    in
    (*TODO: modify this method so that try_ext code = lss id*)
    let extend_with_loopsum l id =      
      let rec extend l level =
        match l with
          | h::rest -> 
              (let (precond, _, _, _, _, _) = h in 
                 if level < id then
                   (ignore(try_ext trans_func try_func non_try_func false_bit both_fail_func level);
                    add_pc (V.UnOp(V.NEG, precond));
                    extend rest (level+1))
                 else if level = id then
                   (ignore(try_ext trans_func try_func non_try_func true_bit both_fail_func level);
                    add_pc precond)
                 else failwith "")
          | [] -> ()
      in
        extend l 1
    in
      if not (self#get_iter = 2) then ([], 0L)
      else let feasibles = get_feasible lss in 
        (match loopsum_status with
           (*NOTE: should also extend useLoopsum node for Some ture/false status? *)
           | Some true -> 
               Printf.eprintf "Loopsum has been applied in 0x%Lx\n" eip; ([], 0L)
           | Some false -> 
               Printf.eprintf "Loop has been checked but no loopsum applies in 0x%Lx\n" eip; ([], 0L)
           | None -> 
               (if use_loopsum feasibles then
                  (loopsum_status <- Some true;
                   let (n, id, vt, eeip) =  choose_loopsum feasibles in
                     Printf.eprintf "Choose loopsum[%d]\n" id;
                     extend_with_loopsum feasibles (n+1);
                     (vt, eeip))
                else 
                  (loopsum_status <- Some false;
                   ([], 0L))))

  (* Print loopsum status when exiting a loop*)
  method finish_loop = 
    if !opt_trace_loopsum then
      (self#print_gt gt;
       self#print_ivt ivt;
       self#print_bdt bdt)
       

  method reset =
    iter <- 0;
    loopsum_status <- None;
    ivt <- [];
    gt <- [];

  method make_snap =
    snap_bdt <- bdt;    
    iter_snap <- iter;
    loopsum_status_snap <- loopsum_status

  method reset_snap =
    bdt <- snap_bdt;
    iter <- iter_snap;
    loopsum_status <- loopsum_status_snap

  initializer 
    self#compute_loop_body tail head g;

end

(*Manage a simpe_graph and the corresponding loop stack*)
(*Automatic loop detection*)
class dynamic_cfg (eip : int64) = object(self)
  val g = new simple_graph eip
  val mutable current_node = -1L
  val mutable current_node_snap = -1L

  (* The eip of the 1st instruction in the procedure *)
  val head = eip

  method get_head = head

  (* To handle nested loops, track the current loop with a stack *)
  (* Each element is the id of a loop *)
  val mutable loopstack = Stack.create ()
  val mutable loopstack_snap = Stack.create ()

  (* A full List of loops in current subroutine*)
  (* Hashtbl loop head -> loop record *)
  val mutable looplist = Hashtbl.create 10	
                         
  (* Check the all_seen status of loops on current path *)
  (* If all the true subtrees of loopsums and the false subtree of useLoopsum*) 
  (* are all_seen, then mark the false side of last loopsum to all_seen*)
  method mark_extra_all_seen (loop_enter_nodes: (int * loop_record) list)  
                           mark_all_seen (is_all_seen: int -> bool) get_t_child
                           get_f_child =
    let rec subtree_all_seen node =
      Printf.eprintf "subtree_all_seen(%d)\n" node;
      if not (((get_t_child node) = -1) || (is_all_seen (get_t_child node))) then -1
      else if not ((get_f_child node) = -1) then 
        subtree_all_seen (get_f_child node)
      else
        node
         
    in
      if !opt_trace_loopsum then
        Printf.eprintf "Current path covered %d loop(s)\n" (List.length loop_enter_nodes);
      List.iter (fun (node, loop) ->
                   if is_all_seen (get_f_child node) then
                     (let n = subtree_all_seen (get_t_child node) in
                        Printf.eprintf "Try to mark all_seen, node %d\n" n;
                        if n >= 0 then mark_all_seen n)
      ) loop_enter_nodes

  method get_loop_head = 
    let loop = self#get_current_loop in
      match loop with
        | None -> -1L
        | Some l -> l#get_head

  method get_iter = 
    let loop = self#get_current_loop in
      match loop with
        | None -> 0
        | Some l -> l#get_iter

  method update_ivt simplify check = 
    let loop = self#get_current_loop in
      match loop with
        | None -> ()
        | Some l -> l#update_ivt simplify check

  method add_iv addr exp =
    let loop = self#get_current_loop in
      match loop with
        | None -> ()
        | Some l  -> l#add_iv addr exp

  method is_iv_cond cond=
    let loop = self#get_current_loop in
      match loop with
        | None -> false
        | Some l  -> l#is_iv_cond cond

  method add_g g check simplify =
    let loop = self#get_current_loop in
      match loop with
        | None -> ()
        | Some l  -> l#add_g g check simplify 

  method add_bd eip b = 
    let loop = self#get_current_loop in
      match loop with
        | None -> ()
        | Some l  -> l#add_bd eip b

  method add_slice eip cond slice = 
    let loop = self#get_current_loop in
      match loop with
        | None -> ()
        | Some l  -> l#add_slice eip cond slice

  method find_slice eip = 
    let loop = self#get_current_loop in
      match loop with
        | None -> false
        | Some l  -> l#find_slice eip

  method is_known_guard eip = 
    let loop = self#get_current_loop in
      match loop with
        | None -> None
        | Some l ->
            (if not (l#in_loop eip) then None
             else 
               let res = ref None in
                 List.iter (fun (_, gt, _, _) ->
                              if !res = None then res := l#is_known_guard eip gt
                 ) l#get_lss;
                 !res)

  method private is_parent lp lc = 
    let head = lc#get_head in
      Printf.eprintf "head: 0x%08Lx\n" head;
      if (lp#in_loop head) then true else false

  method private get_current_loop =
    if Stack.is_empty loopstack then None 
    else (		
      let current_loop = Stack.top loopstack in
      let loop = Hashtbl.find looplist current_loop in Some loop 
    )

  (* Return bool * bool: whether enter a loop * whether enter a different loop*)	
  method private enter_loop src dest =
    let msg = ref "" in
    let is_backedge t h = g#is_dom t h in 
    let current_head = 
      (match (self#get_current_loop) with
         | None -> -1L
         | Some loop -> loop#get_head)
    in
      if Hashtbl.mem looplist dest then 
        (if !opt_trace_loop then 
           msg := !msg ^ (Printf.sprintf "Find loop in looplist, head = 0x%08Lx\n" dest);
         let l = Hashtbl.find looplist dest in
           l#compute_loop_body src dest g;
           (true, true, Some l, !msg))
      else if current_head = dest then 
        (if !opt_trace_loop then
           msg := !msg ^ (Printf.sprintf "Stay in the same loop, head = %Lx\n" dest);
         let l = self#get_current_loop in
           (true, false, l, !msg))
      else if is_backedge src dest then 
        (if !opt_trace_loop then
           msg := !msg ^ (Printf.sprintf "Find backedge 0x%Lx --> 0x%Lx\n" src dest);
         let loop = new loop_record src dest g in
           (true, true, Some loop, !msg)
        )
      else (false, false, None, "")

  method private exit_loop eip = 
    let loop = self#get_current_loop in
      match loop with 
        | None -> (None, false)
        | Some l -> (loop, not (l#in_loop eip))

  method in_loop eip = 
    let loop = self#get_current_loop in
      match loop with
        | None -> false
        | Some l -> l#in_loop eip

  method is_loop_head eip = Hashtbl.mem looplist eip 

  method check_loopsum eip check add_pc simplify load_iv eval_cond unwrap_temp
                              try_ext random_bit is_all_seen query_unique_value
                              cur_ident get_t_child get_f_child add_loopsum_node run_slice = 
    let trans_func (_ : bool) = V.Unknown("unused") in
    let try_func (_ : bool) (_ : V.exp) = true in
    let non_try_func (_ : bool) = () in
    let both_fail_func (b : bool) = b in
    let loop = self#get_current_loop in
      match loop with
        | Some l -> 
            (let add_node ident = add_loopsum_node ident l in 
               l#check_loopsum eip check add_pc simplify load_iv eval_cond unwrap_temp
                 try_ext random_bit is_all_seen query_unique_value
                 cur_ident get_t_child get_f_child add_node run_slice)
        | None -> 
            ignore(try_ext trans_func try_func non_try_func (fun() -> false) both_fail_func 0xffff);
            ([], 0L)

  (* NOTE: maybe rewrite this method with new structure, merge enter_loop and *)
  (* exit_loop, and add new loop to looplist*)
  method add_node (eip:int64) =
    let res =
      (if current_node = -1L then
         (g#add_node eip; NotInLoop)
       else
         (g#add_edge current_node eip;
          match (self#enter_loop current_node eip) with
            (* Enter the same loop*)
            | (true, false, loop, msg) -> 
                (match loop with
                   | Some l -> 
                       (l#inc_iter; 
                        if !opt_trace_loop then Printf.eprintf "%s" msg;
                        EnterLoop)
                   | None -> ErrLoop)
            (* Enter a different loop *)
            | (true, true, loop, msg) -> 
                (Stack.push eip loopstack;
                 match loop with
                   | Some lp -> 
                       (lp#inc_iter;
                        if not (Hashtbl.mem looplist eip) then Hashtbl.add looplist eip lp;
                        if !opt_trace_loop then 
                          Printf.eprintf "Enter loop from %Lx -> %Lx\n%s" 
                            current_node eip msg;
                        if !opt_trace_loop_detailed then 
                          Printf.eprintf "Add head = %Lx to looplist\n" eip;
                          Printf.eprintf "At iter %d, there are %d loop(s) in list\n" 
                            lp#get_iter (Hashtbl.length looplist);
                        EnterLoop)
                   | None -> ErrLoop)	
            | (_, in_loop, _, msg) ->
                (match self#exit_loop eip with
                   (* Exit loop *)
                   | (Some l, true) ->
                       (if !opt_trace_loop && (l#get_iter > 0) then 
                          Printf.eprintf "%sEnd loop %Lx on %d-th iter\n" 
                            msg (l#get_head) (l#get_iter);
                        if (l#get_status != Some true) 
                        && (self#get_iter > 2) then
                          (l#save_lss current_node;
                           l#finish_loop);
                        l#reset;
                        ExitLoop)
                   | _ -> if in_loop then InLoop else NotInLoop)))
    in
      current_node <- eip;
      res

  method private count_loop = 
    let count = Stack.length loopstack in
      Printf.eprintf "Current dcfg (0x%08Lx) have %d loops in active\n" head count

  method reset = 
    if !opt_trace_loopsum_detailed then
      Printf.eprintf "Reset dcfg starts with %Lx\n" head;
    g#reset; 
    current_node <- -1L;

  method make_snap =
    if !opt_trace_loopsum_detailed then
      Printf.eprintf "make_snap dcfg starts with %Lx\n" head;
    g#make_snap;
    Hashtbl.iter (fun _ l -> l#make_snap) looplist;
    current_node_snap <- current_node;
    loopstack_snap <- Stack.copy loopstack

  method reset_snap =
    if !opt_trace_loopsum_detailed then
      Printf.eprintf "Reset_snap dcfg starts with %Lx\n" head;
    g#reset_snap;
    current_node <- current_node_snap;
    loopstack <- Stack.copy loopstack_snap;
    let func hd l = 
      if (l#in_loop current_node) then 
          (Stack.push hd loopstack;
           l#reset_snap
          )
    in
      Hashtbl.iter func looplist  

end

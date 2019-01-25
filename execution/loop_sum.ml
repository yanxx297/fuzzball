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

let simplify_cond simplify exp = 
  let rec is_flag e = 
    (match e with
       | V.BinOp(op, exp1, exp2) -> 
           (match op with                
              | (V.EQ | V.NEQ | V.SLT | V.SLE | V.LT | V.LE) -> true
              | _ -> ((is_flag exp1)&&(is_flag exp2)))
       | _ -> (false)) in
    if is_flag exp then simplify exp else exp

let print_set set = 
  Printf.eprintf "Set = {";
  DS.iter (fun d -> Printf.eprintf "0x%08Lx, " d) set;
  Printf.eprintf "}\n";

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

(*A graph class contains some basic operations and automatic dominator computation*)
class simple_graph (h: int64) = object(self)
  val head = h
  val mutable nodes = Hashtbl.create 100
  val successor = Hashtbl.create 100
  val predecessor = Hashtbl.create 100

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
    if not (Hashtbl.mem nodes tail) then 
      self#add_node tail;
    Hashtbl.add successor tail head;
    Hashtbl.add predecessor head tail;
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
      if res = true then 
        (Printf.eprintf "0x%08Lx -> 0x%08Lx " x d;
         print_set dom);
(*
      (match res with
        | true -> Printf.eprintf "0x%Lx dominates 0x%Lx[%d]\n" d x (DS.cardinal dom)
        | false -> Printf.eprintf "0x%Lx doesn't dominate 0x%Lx[%d]\n" d x (DS.cardinal dom));
 *)
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

  (* Branch table: (branch_eip(int64), cond(exp), current_decision(int64))
   collect branch conditions in loop and use them to 
   compute pre conditions.*)
  val mutable bt = Hashtbl.create 10		
  val mutable snap_bt = Hashtbl.create 10	

  (* lss(loopsum set): (enter_cond, exit_cond) *)
  (* enter_cond = precond && branch conditions *)
  (* exit_cond = (precond, VT, exit_eip) *)
  val mutable lss = []
  method get_lss = lss
  method set_lss s = lss <- s

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

  method update_loopsum = (
    loopsum_status <- None
  (**If we clear up LS set after each updating, we must also remove the corresponding decision sub-tree*)
  (*lss <- []*))

  method get_loop_body = loop_body

  method private get_min_s ty =
    match ty with
      | V.REG_1 -> (0x1L)
      | V.REG_8 -> (0x80L)
      | V.REG_16 -> (0x8000L)
      | V.REG_32 -> (0x80000000L)
      | V.REG_64 -> (0x8000000000000000L)
      | _  -> failwith "Illegal type\n" 

  method private get_min_u ty = 
    match ty with
      | V.REG_1 -> (0x1L)
      | V.REG_8 -> (0xffL)
      | V.REG_16 -> (0xffffL)
      | V.REG_32 -> (0xffffffffL)
      | V.REG_64 -> (0xffffffffffffffffL)
      | _  -> failwith "Illegal type\n" 

  method inc_iter = 
    iter <- (iter + 1);
    if !opt_trace_loop then (
      Printf.eprintf "----------------------------------------------------------------------------\n";
      Printf.eprintf "iter [+1] : %d\n" iter)

  method get_iter = iter

  method private simplify_exp simplify exp = simplify exp

  method reset =
    iter <- 0;
    loopsum_status <- None;
    self#clean_ivt;
    self#clean_gt;
    self#clean_bt      

  method make_snap =
    snap_bt <- bt;
    iter_snap <- iter;
    loopsum_status_snap <- loopsum_status

  method reset_snap =
    bt <- snap_bt;
    iter <- iter_snap;
    loopsum_status <- loopsum_status_snap

  val mutable ivt = []	(**addr | (V_0, V, V', dV)*)
  val iv_cond_t = Hashtbl.create 10

  method private ivt_search addr = 
    let res = ref None in
    let loop ((eip, v0, v, v', dv_opt) as iv) = (
      if eip = addr then res := Some iv
    ) in 
      List.iter loop ivt;
      !res

  method is_iv_cond cond = 
    let res = Hashtbl.mem iv_cond_t cond in
      res

  method renew_ivt s_func check =
    let len = List.length ivt in
    let cmp (addr, v0, v, v', dv_opt) =
      match iter with
        | 2 -> self#replace_iv (addr, v0, v', v', dv_opt)
        | _ -> (
            let dv' = V.BinOp(V.MINUS, v', v) in 
              match dv_opt with
                | None -> self#replace_iv (addr, V.BinOp(V.MINUS, v0, dv'), v', v', Some dv')
                | Some dv -> (
                    let cond = V.BinOp(V.EQ, dv, dv') in
                      if !opt_trace_loopsum_detailed then 
                        Printf.eprintf "iv cond (full): %s \n" (V.exp_to_string cond);
                      let cond' = simplify_cond s_func cond in
                        (if !opt_trace_ivt then 
                           Printf.eprintf "IV cond (simplified): %s \n" (V.exp_to_string cond');
                         match cond' with
                           | V.Constant(V.Int(V.REG_1, 1L)) -> ()
                           | V.Constant(V.Int(V.REG_1, 0L)) -> self#clean_ivt
                           | _ ->
                               (if check cond' then
                                  Hashtbl.replace iv_cond_t cond ()
                               else
                                 self#clean_ivt));
                        self#replace_iv (addr, v0, v', v', Some dv')
                  ))
    in
      if iter >= 2 then List.iter cmp ivt;
      let len' = List.length ivt in
        if (len' - len) < 0 then Some false else Some true 

  method get_ivt = ivt

  method in_loop eip = 
    let res = Hashtbl.mem loop_body eip in
      if !opt_trace_loop_detailed then
        (match res with
           | true -> (Printf.eprintf "0x%08Lx is in the loop <0x%08Lx>\n" eip id)
           | false  -> (Printf.eprintf "0x%08Lx is not in the loop <0x%08Lx>\n" eip id));
      res

  method private replace_iv (addr, v0, v, v', dv) = 
    let rec loop l = (
      match l with
        | iv::l' -> (
            let (addr', _, _, _, _) = iv in
              if addr' = addr then [(addr, v0, v, v', dv)] @ l' 
              else [iv] @ (loop l'))
        | [] -> []
    ) in
      ivt <- loop ivt

  method add_iv (addr: int64) (exp: V.exp) =
(*     Printf.eprintf "add_iv: try mem[0x%08Lx] \n" addr; *)
    match (self#ivt_search addr) with
      | Some iv -> (
          let (addr, v0, v, v', dv) = iv in
            if not (v' = exp) then self#replace_iv (addr, v0, v, exp, dv);)
(*
            if !opt_trace_ivt then 
               Printf.eprintf "add_iv: replace %s with %s at 0x%08Lx\n" (V.exp_to_string v') (V.exp_to_string exp) addr) 
 *)
      | None -> (
          if iter = 2 then (
            ivt <- ivt @ [(addr, exp, exp, exp, None)];)
(*             if !opt_trace_ivt then Printf.eprintf "add_iv: Store [0x%08Lx] = %s\n" addr (V.exp_to_string exp)) *)
          else (
            if !opt_trace_ivt then Printf.eprintf " 0x%08Lx not exist in ivt\n" addr)			
        ) 

  method clean_ivt = 
    if !opt_trace_ivt then Printf.eprintf "clean IVT of 0x%08Lx\n" id;
    ivt <- [];

  (*Gate table: (eip | (EC, op, ty, D0, D, D', dD, exit_eip)*)
  (* EC: the expected execution count*)
  val mutable gt = [] 
  val g_cond_t = Hashtbl.create 10 (**TODO: figure out whether to remove this container*)

  (**(addr | _): A list of guards that are integer overflow*)
  val iof_cache = Hashtbl.create 10   

  method private gt_search addr = 
    let res = ref None in
    let loop ((eip, ec, op, ty, d0, d, d', dD, eeip) as g) = (
      if eip = addr then res := Some g
    ) in 
      List.iter loop gt;
      !res

  (* Add or update a guard table entry*)
  method add_g (addr: int64) lhs rhs op' ty s_func check (eeip: int64) =
(*     Printf.eprintf "add_g: iter %d, op = %s\n" iter (V.binop_to_string op'); *)
    let check_cond e = 
      let res = check e in
        if res then Hashtbl.replace g_cond_t e ();
        res
    in
    let compute_ec op d dD addr = 
      let exp =
        let sum = V.BinOp(V.PLUS, d, dD) in
        let iof = 
          match op with
            | V.SLE | V.SLT| V.EQ -> check_cond (V.BinOp(V.SLT, sum, d))
            | V.LE | V.LT -> check_cond (V.BinOp(V.LT, sum, d))
            | _ -> failwith ""
        in
          if iof then
            Some (V.BinOp(V.PLUS, V.BinOp(V.DIVIDE, V.BinOp(
              V.MINUS, d, V.Constant(V.Int(ty, 1L))), dD), V.Constant(V.Int(ty, 1L))))
          else Some (V.BinOp(V.DIVIDE, V.BinOp(V.MINUS, sum, V.Constant(V.Int(ty, 1L))), dD))
      in
        match (self#gt_search addr) with
          | Some g -> 
              (let (_, ec, _, _, _, _, _, _, _) = g in
                 match ec with 
                   | Some e -> ec
                   | None -> exp) 
          | None -> exp
    in
    (* Compute D of the current iteration *)
    (* loop_cond := if true, stay in the loop*) 
    (* iof_cond = lhs>0 && rhs<0 && lhs-rhs<lhs; if true, integer overflow can happen when computing D*)
    (**TODO: handle IOF while computing D = lhs - rhs, when lhs >0 and rhs <0*)
    let msg = ref "" in
    let exp = 
      (match op' with
         | V.EQ -> 
             (let d = (V.BinOp(V.MINUS, lhs, rhs)) in
                Some d
             )
         | V.SLE -> 
             (let loop_cond = V.BinOp(V.SLT, rhs, lhs) in
              let iof_cond = 
                V.BinOp(V.BITAND, 
                        V.BinOp(V.BITAND, 
                                V.BinOp(V.SLT, rhs, V.Constant(V.Int(ty, 0L))), 
                                V.BinOp(V.SLT, V.Constant(V.Int(ty, 0L)), lhs)), 
                        V.BinOp(V.SLT, V.BinOp(V.MINUS, lhs, rhs), lhs)) 
              in 
                msg := !msg ^ (Printf.sprintf "add_g: loop_cond %s\n" (V.exp_to_string (s_func V.REG_1 loop_cond)));
                msg := !msg ^ (Printf.sprintf "add_g: iof_cond %s\n" (V.exp_to_string (s_func V.REG_1 iof_cond)));
                if check_cond loop_cond then
                  if check_cond iof_cond then None
                  else if (Hashtbl.mem iof_cache addr) then
                    Some (V.BinOp(V.MINUS, V.Constant(V.Int(ty, self#get_min_s ty)), lhs))
                  else
                    Some (V.BinOp(V.MINUS, lhs, rhs))
                else None
             )
         | V.SLT -> 
             (let loop_cond = V.BinOp(V.SLE, rhs, lhs) in
              let iof_cond = 
                V.BinOp(V.BITAND, 
                        V.BinOp(V.BITAND, 
                                V.BinOp(V.SLT, rhs, V.Constant(V.Int(ty, 0L))), 
                                V.BinOp(V.SLT, V.Constant(V.Int(ty, 0L)), lhs)), 
                        V.BinOp(V.SLT, V.BinOp(V.MINUS, lhs, rhs), lhs)) 
              in 
                msg := !msg ^ (Printf.sprintf "add_g: loop_cond %s\n" (V.exp_to_string (s_func V.REG_1 loop_cond)));
                msg := !msg ^ (Printf.sprintf "add_g: iof_cond %s\n" (V.exp_to_string (s_func V.REG_1 iof_cond)));
                if check_cond loop_cond then
                  if check_cond iof_cond then None
                  else if (Hashtbl.mem iof_cache addr) then
                    Some (V.BinOp(V.MINUS, V.Constant(V.Int(ty, self#get_min_s ty)), lhs))
                  else Some (V.BinOp(V.MINUS, lhs, rhs))
                else None
             )
         | V.LE -> 
             (let cond = V.BinOp(V.LT, rhs, lhs) in
                if check_cond cond then Some (V.BinOp(V.MINUS, lhs, rhs)) 
                else None
             )
         | V.LT -> 
             (let cond = V.BinOp(V.LE, rhs, lhs) in
                if check_cond cond then Some (V.BinOp(V.MINUS, lhs, rhs))
                else None
             )
         | _  -> None
      ) 
    in
      if !opt_trace_loopsum_detailed then Printf.eprintf "%s" !msg;
      let msg = ref "" in
      (*For each case, compute dd, check IOF according to D and dd, compute EC if not yet*)
      (*check whether dd' = dd, and then copy D' to D at the end*)
      (match exp with
         | None -> 
             (Printf.eprintf "add_g: fail to compute D\n")
         | Some e -> (
             match self#gt_search addr with
               | Some g -> (
                   let msg = ref "" in
                   let (_, ec, op, _, d0_opt, d_opt, d_opt', dd_opt, eeip) = g in
                     if not (d_opt' = exp) then self#replace_g (addr, ec, op, ty, d0_opt, d_opt, exp, dd_opt, eeip);
                     let (dist_opt, dD_opt, eCount_opt) = 
                       (match (d_opt, exp) with
                          | (Some d, Some d') -> 
                              (match op with
                                 | V.SLE -> 
                                     (let dd' = s_func ty (V.BinOp(V.MINUS, d', d)) in
                                      let cond1 = V.BinOp(V.SLT, V.Constant(V.Int(ty, 0L)), d')
                                      and cond2 = V.BinOp(V.SLT, dd', V.Constant(V.Int(ty, 0L))) in
                                        if !opt_trace_gt then 
                                          (msg := !msg ^ (Printf.sprintf "dd = %s\n" (V.exp_to_string (V.BinOp(V.MINUS, d', d))));
                                           msg := !msg ^ (Printf.sprintf "dd' = %s\n" (V.exp_to_string dd'));
                                           msg := !msg ^ (Printf.sprintf "cond1 = %s\n" (V.exp_to_string cond1));
                                           msg := !msg ^ (Printf.sprintf "cond2 =  %s\n" (V.exp_to_string cond2)));
                                        match ((check_cond cond1), (check_cond cond2)) with
                                          | (true, true) -> 
                                              (*D>0 && d<0*)
                                              (Some d', Some dd', (compute_ec op d (V.UnOp(V.NEG, dd')) addr))
                                          | (true, false) -> (
                                              (*integer overflow: D>0 && d>=0*)
                                              Hashtbl.replace iof_cache addr ();
                                              msg := !msg ^ (Printf.sprintf "Int Overflow!!!\n");
                                              let iof_d = s_func ty (V.BinOp(V.MINUS, V.Constant(V.Int(ty, self#get_min_s ty)), lhs)) in
                                              let iof_dd = s_func ty (V.UnOp(V.NEG, dd')) in
                                              let iof_d' = (V.BinOp(V.MINUS, iof_d, iof_dd)) in
                                              let iof_cond = (V.BinOp(V.SLT, iof_d', iof_d)) in
                                                if check_cond iof_cond then
                                                  (Some iof_d, Some iof_dd, (compute_ec op iof_d dd' addr))
                                                else
                                                  (Some iof_d, Some iof_dd, (compute_ec op iof_d' dd' addr))
                                            )
                                          | _  -> failwith "Unexpected SLE situation: this should not happen")
                                 | V.SLT -> 
                                     (let dd' = s_func ty (V.BinOp(V.MINUS, d', d)) in
                                      let cond1 = V.BinOp(V.SLE, V.Constant(V.Int(ty, 0L)), d')
                                      and cond2 = V.BinOp(V.SLT, dd', V.Constant(V.Int(ty, 0L))) in
                                        match ((check_cond cond1), (check_cond cond2)) with
                                          | (true, true) -> 
                                              (*D>=0 && d<0*)
                                              (Some d', Some dd', (compute_ec op d (V.UnOp(V.NEG, dd')) addr))
                                          | (true, false) -> 
                                              (*integer overflow: D>0 && d>=0*)
                                              (Hashtbl.replace iof_cache addr ();
                                               let iof_d = s_func ty (V.BinOp(V.MINUS, V.Constant(V.Int(ty, self#get_min_s ty)), lhs)) in
                                               let iof_dd = s_func ty (V.UnOp(V.NEG, dd')) in
                                               let iof_d' = (V.BinOp(V.MINUS, iof_d, iof_dd)) in
                                               let iof_cond = (V.BinOp(V.SLT, iof_d', iof_d)) in
                                                 if check_cond iof_cond then
                                                   (Some iof_d, Some iof_dd, (compute_ec op iof_d dd' addr))
                                                 else 
                                                   (Some iof_d, Some iof_dd, (compute_ec op iof_d' dd' addr))
                                              )
                                          | _  -> failwith "Unexpected SLT situation: this should not happen")
                                 | V.LE -> 
                                     (let cond1 = V.BinOp(V.LT, V.Constant(V.Int(ty, 0L)), d')
                                      and cond2 = V.BinOp(V.LT, d', d) in
                                        match ((check_cond cond1), (check_cond cond2)) with
                                          | (true, true) -> 
                                              (*D>0 && d<0*)
                                              (let dd' = V.BinOp(V.MINUS, d, d') in
                                                 (Some d', Some dd', (compute_ec op d' dd' addr)))
                                          | (true, false) -> 
                                              (*d = D'-D > 0, integer overflow*)
                                              (Hashtbl.replace iof_cache addr ();
                                               let iof_d = s_func ty (V.BinOp(V.MINUS, V.Constant(V.Int(ty, self#get_min_u ty)), lhs)) in
                                               let dd' = V.BinOp(V.MINUS, d', d) in
                                               let iof_d' = V.BinOp(V.PLUS, iof_d, dd') in
                                               let iof_cond = (V.BinOp(V.LT, iof_d', iof_d)) in
                                                 if check_cond iof_cond then
                                                   (Some iof_d, Some dd', (compute_ec op iof_d dd' addr))
                                                 else
                                                   (Some iof_d, Some dd', (compute_ec op iof_d' dd' addr)))
                                          | _ -> failwith "Unexpected LE situation: this should not happen")
                                 | V.LT -> 
                                     (let cond1 = V.BinOp(V.LE, V.Constant(V.Int(ty, 0L)), d')
                                      (**cond1 may not be necessary, since an unsigend int is always >= 0*)
                                      and cond2 = V.BinOp(V.LT, d', d) in
                                        match ((check_cond cond1), (check_cond cond2)) with
                                          | (true, true) -> 
                                              (*D>=0 && d<0*)
                                              (let dd' = V.BinOp(V.MINUS, d, d') in
                                                 (Some d', Some dd', (compute_ec op d' dd' addr)))
                                          | (true, false) -> 
                                              (*d = D'-D > 0, integer overflow*)
                                              (Hashtbl.replace iof_cache addr ();
                                               let iof_d = s_func ty (V.BinOp(V.MINUS, V.Constant(V.Int(ty, self#get_min_u ty)), lhs)) in
                                               let dd' = V.BinOp(V.MINUS, d', d) in
                                               let iof_d' = V.BinOp(V.PLUS, iof_d, dd') in
                                               let iof_cond = (V.BinOp(V.LT, iof_d', iof_d)) in
                                                 if check_cond iof_cond then
                                                   (Some iof_d, Some dd', (compute_ec op iof_d dd' addr))
                                                 else
                                                   (Some iof_d, Some dd', (compute_ec op iof_d' dd' addr)))
                                          | _ -> failwith "Unexpected LT situation: this should not happen")
                                 | V.EQ -> 
                                     (let dd' = s_func ty (V.BinOp(V.MINUS, d', d)) in
                                      let loop_cond = V.BinOp(V.NEQ, d', V.Constant(V.Int(ty, 0L))) in
                                        if check_cond loop_cond then
                                          (let iof_cond = V.BinOp(V.NEQ, dd', V.Constant(V.Int(ty, 0L))) in
                                             if check_cond iof_cond then
                                               (let cond1 = V.BinOp(V.SLT, V.Constant(V.Int(ty, 0L)), d')
                                                and cond2 = V.BinOp(V.SLT, V.Constant(V.Int(ty, 0L)), dd') in
                                                  (match (check_cond cond1, check_cond cond2) with 
                                                     | (true, true)
                                                     | (true, false) -> 
                                                         (*If Both situations are possible, take the (D > 0, d < 0) case first*)
                                                         (msg := !msg ^ (Printf.sprintf "default EQ\n");
                                                          (Some d', Some dd',(compute_ec op d'(V.UnOp(V.NEG, dd')) addr)))
                                                     | (false, true) -> 
                                                         (msg := !msg ^ (Printf.sprintf "inverse EQ\n");
                                                          (Some d', Some dd', (compute_ec op (V.UnOp(V.NEG, d')) dd' addr)))
                                                     | _ -> 
                                                         (** TODO: Handle integer overflow (dD and D on the same direction)*)
                                                         (None, None, None)))
                                             else
                                               (msg := !msg ^ (Printf.sprintf "dd' = 0: Infinity loop\n");
                                                (None, None, None))
                                          )
                                        else (None, None, None))
                                 |_ -> failwith "add_g: illegal operation\n")
                          | _ -> (None, None, None)) 
                     in
                       (match (dist_opt, dD_opt, eCount_opt) with
                          | (Some dist, Some dD, Some eCount) -> 
                              (msg := !msg ^ (Printf.sprintf "%s\n" (V.exp_to_string dD));
                               self#replace_g (addr, eCount_opt, op, ty, d0_opt, dist_opt, dist_opt, dD_opt, eeip);
                              )
                          | _  -> ());
                       if !opt_trace_gt then 
                         (let d_str = 
                            (match d_opt' with
                               | None -> "<None>"
                               | Some d -> (V.exp_to_string d)) 
                          in
                            msg := !msg ^ (Printf.sprintf "add_g: replace %s with %s at 0x%08Lx\n" d_str (V.exp_to_string e) addr);
                            if !opt_trace_loopsum_detailed then Printf.eprintf "%s" !msg
                         )
                 )
               | None -> (
                   if iter = 2 then (
                     gt <- gt @ [(addr, None, op', ty, exp, exp, exp, None, eeip)];
                     if !opt_trace_gt then 
                       msg := !msg ^ (Printf.sprintf "add_g: Store [0x%08Lx] = %s\n" addr (V.exp_to_string e));
                     if !opt_trace_loopsum_detailed then Printf.eprintf "%s" !msg
                   )
                 )))

  method is_gt_cond cond = 
    let res = Hashtbl.mem g_cond_t cond in
      res

  method print_ivt = 
    let loop i (addr, v0, v, v', dv) = (
      Printf.eprintf "[%d]\tmem[0x%08Lx] = %s " i addr (V.exp_to_string v0);
      match dv with
        | Some d -> Printf.eprintf "\t(+ %s)\n" (V.exp_to_string d)
        | None -> Printf.eprintf "\n"
    )in
      List.iteri loop ivt

  method print_ec =
    let loop i (addr, ec, op, typ, d0_opt, d_opt, d_opt', dd_opt, eeip) = (
      (match ec with
         | Some exp -> (Printf.eprintf "[%d] mem[0x%08Lx] = %s (eeip: %Lx)\n" i addr (V.exp_to_string exp) eeip)
         | None  -> (Printf.eprintf "[%d] mem[0x%08Lx] = None (eeip: %Lx)\n" i addr eeip)
      );
    )
    in
      List.iteri loop gt

  method get_gt = gt

  method private replace_g (addr, ec, opt, ty, d0, d, d', dd, eeip) = 
    let rec loop l =
      match l with
        | g::l' -> (
            let (addr', _, _, _, _, _, _, _, _) = g in
              if addr' = addr then [(addr, ec, opt, ty, d0, d, d', dd, eeip)] @ l'
              else[g] @ (loop l'))
        | [] -> []
    in
      gt <- loop gt

  method clean_gt = 
    if !opt_trace_gt then Printf.eprintf "clean GT of 0x%08Lx\n" id;
    gt <- [] 


  method add_bd (eip:int64) (e: V.exp) (d:int64) = (
    if !opt_trace_loopsum_detailed then
      Printf.eprintf "add_bd: at 0x%08Lx, cond = %s\n" eip (V.exp_to_string e); 
    Hashtbl.replace bt eip (e, d))

  method check_bt eip = (
    try (Some (Hashtbl.find bt eip)) with
      | Not_found -> None)

  method clean_bt = (
    bt <- Hashtbl.create 10)

  method get_head = id

  method add_insn (eip:int64) = 
    Hashtbl.add loop_body eip ()

  (*Compute loop sum set: (precond, postcond set, exit_eip) List*)
  method compute_lss eip apply =
    let compute_enter_cond bt gt = (
      let rec guard_cond l = (
        match l with
          | h::l' -> (
              let (addr, ec, op, ty, d0_opt, d_opt, d_opt', dd_opt, eeip) = h in
              let cond = 
                (match (d0_opt, dd_opt) with
                   | (Some d0, Some dd) -> 
                       (match op with
                          | V.EQ -> (V.BinOp(V.BITAND, 
                                             V.BinOp(V.NEQ, d0, V.Constant(V.Int(ty, 0L))), 
                                             V.BinOp(V.NEQ, dd, V.Constant(V.Int(ty, 0L)))))
                          | V.NEQ -> (V.BinOp(V.BITAND, 
                                              V.BinOp(V.EQ, d0, V.Constant(V.Int(ty, 0L))), 
                                              V.BinOp(V.NEQ, dd, V.Constant(V.Int(ty, 0L)))))
                          | V.SLT -> (V.BinOp(V.BITAND, 
                                              V.BinOp(V.SLE, V.Constant(V.Int(ty, 0L)), d0), 
                                              V.BinOp(V.NEQ, dd, V.Constant(V.Int(ty, 0L)))))
                          | V.SLE -> (V.BinOp(V.BITAND, 
                                              V.BinOp(V.SLT, V.Constant(V.Int(ty, 0L)), d0), 
                                              V.BinOp(V.NEQ, dd, V.Constant(V.Int(ty, 0L)))))
                          | V.LT -> (V.BinOp(V.BITAND, 
                                             V.BinOp(V.LE, V.Constant(V.Int(ty, 0L)), d0), 
                                             V.BinOp(V.NEQ, dd, V.Constant(V.Int(ty, 0L)))))
                          | V.LE -> (V.BinOp(V.BITAND, 
                                             V.BinOp(V.LT, V.Constant(V.Int(ty, 0L)), d0), 
                                             V.BinOp(V.NEQ, dd, V.Constant(V.Int(ty, 0L)))))
                          | _ -> failwith "Invalid operator in compute_enter_cond")
                   | (Some d0, None) -> (Printf.eprintf "lack dD\n"; raise LoopsumNotReady) 
                   | (None, Some dd) -> (Printf.eprintf "lack D0\n"; raise LoopsumNotReady)
                   | _ -> (Printf.eprintf "Invalid GT entry in compute_enter_cond\n"; raise LoopsumNotReady)) in
                V.BinOp(V.BITAND, cond, (guard_cond l')))
          | [] -> V.Constant(V.Int(V.REG_1, 1L))
      ) 
      in
      let branch_cond = ref (V.Constant(V.Int(V.REG_1, 1L))) in
      let compute_branch_cond addr (cond, d) = (
        branch_cond := V.BinOp(V.BITAND, !branch_cond, cond)) 
      in
        Hashtbl.iter compute_branch_cond bt;
        V.BinOp(V.BITAND, (guard_cond gt), !branch_cond)) 
    in
    let min_ec i l = (
      let (_, e, _, ty, _, _, _, _, _) = List.nth l i in
      let ec = (
        match e with
          | Some exp -> exp
          | None -> (Printf.eprintf "Invalid GT entry in min_ec\n"; raise LoopsumNotReady)) in 
      let rec loop idx l = 
        (match l with
           | h::l' -> (
               if idx > 0 then (
                 let (_, e', _, _, _, _, _, _, _) = h in
                 let ec' = (
                   match e' with
                     | Some exp -> exp
                     | None -> (Printf.eprintf "Invalid GT entry in min_ec: No EC\n"; raise LoopsumNotReady)) in
                   V.BinOp(V.BITAND, V.BinOp(V.SLT, ec, ec'), (loop (idx-1) l')))
               else if idx < 0 then (
                 let (_, e', _, ty', _, _, _, _, _) = h in
                 let ec' = (
                   match e' with
                     | Some exp -> exp
                     | None -> (Printf.eprintf "Invalid GT entry in min_ec: No EC\n"; raise LoopsumNotReady)) in
                   V.BinOp(V.BITAND, V.BinOp(V.SLE, ec, ec'), (loop (idx-1) l')))
               else (loop (idx-1) l'))
           | [] -> V.Constant(V.Int(V.REG_1, 1L))) in
        loop i l
    ) in
      try (
        if List.length gt = 0 then raise LoopsumNotReady;
        let res = ref [] in
        let enter_cond = compute_enter_cond bt gt in
          Printf.eprintf "----------------------------------------------------------------------------\n";
          Printf.eprintf "* (Pre)enter condition: \n%s\n" (V.exp_to_string enter_cond);
          let loop i (addr, ec_opt, op, typ, d0_opt, d_opt, d_opt', dd_opt, eeip)= (
            let precond = (min_ec i gt) in
            let ec = match ec_opt with
              | Some e -> e
              | None -> (Printf.eprintf "Invalid GT entry: No EC\n"; raise LoopsumNotReady) 
            in
              let rec compute_vt l = (
                match l with
                  | h::l' -> (
                      let (addr, v0, _, _, dv_opt) = h in
                      let dv = match dv_opt with
                        | Some e -> e
                        | None -> (Printf.eprintf "Invalid IVT entry in compute_vt: No dV\n"; raise LoopsumNotReady) in
                      let v' = V.BinOp(V.PLUS, v0, V.BinOp(V.TIMES, ec, dv)) in
                        [(addr, v')] @ (compute_vt l'))
                  | [] -> []
              ) in
              let iv_list = compute_vt ivt in
                res := !res @ [(precond, iv_list, eeip)];
                if (eip = addr) then (apply iv_list)) 
          in
            List.iteri loop gt;
            lss <- lss @ [(enter_cond, !res)];
            Printf.eprintf "* Loopsum set size: %d\n" (List.length lss);
      ) with
        | LoopsumNotReady -> (
            Printf.eprintf "Not ready to compute LS\n";)

  val mutable i = 0	
  method private compute_loop_body tail head g = 
    let rec inc_loopbody eip = 
      if not (eip = head || Hashtbl.mem loop_body eip) then 
        (self#add_insn eip;
         let pred_list = g#pred eip in
           if !opt_trace_loop_detailed then
             (Printf.eprintf "compute_loop_body: { ";
              let print_pred addr = Printf.eprintf "%Lx, " addr in
                List.iter print_pred pred_list;
                Printf.eprintf "} -> %Lx\n" eip);
             List.iter inc_loopbody pred_list;
             i <- 0
        )
    in
      inc_loopbody tail;
      self#add_insn tail;
      self#add_insn head;
      let print_insn eip () = 
        Printf.eprintf " %Lx\n" eip
      in
        if !opt_trace_loop then
          Printf.eprintf "loopbody (%Lx -> %Lx) size: %d\n" tail head (Hashtbl.length loop_body);
        if !opt_trace_loop_detailed then
          Hashtbl.iter print_insn loop_body


  initializer 
    self#compute_loop_body tail head g;
(*         Printf.eprintf "Create a loopRec\n" *)

end

(*Manage a simpe_graph and the corresponding loop stack*)
(*Automatic loop detection*)
class dynamic_cfg (eip : int64) = object(self)
  val g = new simple_graph eip
  val mutable current_node = -1L
  val mutable current_node_snap = -1L
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
  method mark_extra_all_seen (loop_enter_nodes: (int * loop_record option) list)  
                           mark_all_seen (is_all_seen: int -> bool) get_t_child
                           get_f_child =
    let rec mark_loopsum_all_seen num node id = 
      (Printf.eprintf "At node %d, check loopsum %d/%d\n" node id num;
       let mark_last_all_seen cur = 
         (Printf.eprintf "mark_loopsum_all_seen: check node %d\n" cur;
           let t_child = get_t_child cur in
            if not (t_child = -1) then
              (if id = (num - 1) then
                 (Printf.eprintf "Node %d is the last loopsum(ls[%d]), mark it to all_seen\n" cur id;
                  mark_all_seen (get_f_child cur))
               else if (is_all_seen t_child) then
                 mark_loopsum_all_seen num (get_f_child cur) (id+1)
              )
         )
       in
         mark_last_all_seen node)
    in
      if !opt_trace_loopsum then
        Printf.eprintf "Current path covered %d loops\n" (List.length loop_enter_nodes);
      List.iter (fun (node, loop_opt) ->
                   match loop_opt with
                     | Some loop -> 
                         if is_all_seen (get_f_child node) then
                           let num = List.length (loop#get_lss) in
                             mark_loopsum_all_seen num (get_t_child node) 0
                     | None -> Printf.eprintf "Invalid loop head\n"
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

  method get_lss = 
    let loop = self#get_current_loop in
      match loop with
        | None -> []
        | Some l -> l#get_lss 

  method renew_ivt s_func check = 
    let loop = self#get_current_loop in
      match loop with
        | None -> (None)
        | Some l -> l#renew_ivt s_func check

  method add_iv addr exp =
    let loop = self#get_current_loop in
      match loop with
        | None -> ()
        | Some l  -> l#add_iv addr exp

  method clean_ivt =
    let loop = self#get_current_loop in
      match loop with
        | None -> ()
        | Some l  -> l#clean_ivt

  method is_iv_cond cond=
    let loop = self#get_current_loop in
      match loop with
        | None -> false
        | Some l  -> l#is_iv_cond cond

  method add_g addr lhs rhs op' ty s_func check eeip =
    let loop = self#get_current_loop in
      match loop with
        | None -> ()
        | Some l  -> l#add_g addr lhs rhs op' ty s_func check eeip

  method clean_gt =
    let loop = self#get_current_loop in
      match loop with
        | None -> ()
        | Some l  -> l#clean_gt

  method is_gt_cond cond=
    let loop = self#get_current_loop in
      match loop with
        | None -> false
        | Some l  -> l#is_gt_cond cond

  method check_bt eip = (
    let loop = self#get_current_loop in
      match loop with
        | None -> None
        | Some l  -> l#check_bt eip)

  method add_bd eip exp d = (
    let loop = self#get_current_loop in
      match loop with
        | None -> ()
        | Some l  -> l#add_bd eip exp d)

  method private is_parent lp lc = 
    let head = lc#get_head in
      Printf.eprintf "head: 0x%08Lx\n" head;
      if (lp#in_loop head) then true else false

  method get_current_loop =
    if Stack.is_empty loopstack then None 
    else (		
      let current_loop = Stack.top loopstack in
      let loop = Hashtbl.find looplist current_loop in Some loop 
    )

  (* Return bool * bool: whether enter a loop * whether enter a different loop*)	
  method private enter_loop src dest =
    let msg = ref (Printf.sprintf "Enter loop from %Lx -> %Lx\n" src dest) in
    let is_backedge t h = g#is_dom t h in 
    let current_head = 
      (match (self#get_current_loop) with
         | None -> -1L
         | Some loop -> loop#get_head)
    in
      if Hashtbl.mem looplist dest then 
        (if !opt_trace_loop then 
           msg := !msg ^ (Printf.sprintf "Find loop in looplist, head = 0x%08Lx\n" dest);
         (true, true, Some (Hashtbl.find looplist dest), !msg))
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

  (* TODO: rewrite this method with new structure, merge enter_loop & exit_loop, and add new loop to looplist*)
  method add_node (eip:int64) apply =
    let ret =
      (if current_node != -1L 
       then(
         g#add_edge current_node eip;
         match (self#enter_loop current_node eip) with
           | (true, false, loop, msg) -> (
               (* Enter the same loop*)
               match loop with
                 | Some l -> 
                     (l#inc_iter; 
                      if !opt_trace_loop then Printf.eprintf "%s" msg;
                      EnterLoop)
                 | None -> ErrLoop)
           | (true, true, loop, msg) -> (
               (* Enter a different loop *)
               Stack.push eip loopstack;
               match loop with
                 | Some lp -> (
                     lp#inc_iter;
                     if not (Hashtbl.mem looplist eip) then Hashtbl.add looplist eip lp; 
                     if !opt_trace_loop then Printf.eprintf "%s" msg;
                     if !opt_trace_loop_detailed then 
                       Printf.eprintf "At iter %d, there are %d loops in list\n" lp#get_iter (Hashtbl.length looplist);
                     EnterLoop)
                 | None -> ErrLoop	
             )
           | (_, in_loop, _, msg) -> 
               (let (loop, exit) = self#exit_loop eip in
                  if exit then (
                    (* Exit loop *)
                    (match loop with
                       | Some l -> (
                           if !opt_trace_loop then Printf.eprintf "%sEnd on %d-th iter\n" msg (l#get_iter);
                           if (l#get_status != Some true) 
                               && (self#get_iter > 2) && (l#get_lss = []) then 
                             (l#compute_lss current_node apply;
                              if !opt_trace_ivt then(
                                let ivt = l#get_ivt in
                                let ivt_len = List.length ivt in
                                  if ivt_len > 0 then (
                                    Printf.eprintf "* IVT size: %d\n" (ivt_len);
                                    l#print_ivt;
                                  ));
                              if !opt_trace_gt then(
                                let gt = l#get_gt in
                                let gt_len = List.length gt in
                                   (*if gt_len > 0 then*) (
                                     Printf.eprintf "* GT size: %d\n" gt_len;
                                     l#print_ec));
                              Printf.eprintf "----------------------------------------------------------------------------\n";
                             );
                           l#reset;)
                       | None -> (Printf.eprintf "Warning: No loop rec while exiting a loop"));		
                    ignore(try Stack.pop loopstack with Stack.Empty -> 0L); 
                    ExitLoop
                  )
                  else 
                    (match in_loop with
                       | true -> InLoop
                       | false -> NotInLoop)
               )
       )
       else 
         (g#add_node eip;
          NotInLoop)) in
      current_node <- eip;
      ret


  method private count_loop = 
    let count = Stack.length loopstack in
      Printf.eprintf "Current dcfg (0x%08Lx) have %d loops in active\n" head count 

  (* Check whether any existing loop summarization that can fit current
   condition and return the symbolic values and addrs of of IVs.
   NOTE: the update itself implemented in sym_region_frag_machine.ml*)
  (*TODO: loopsum preconds should be add to path cond*)
  method check_loopsum eip check (s_func:Vine.typ -> Vine.exp -> Vine.exp) 
        try_ext (random_bit:bool) (is_all_seen: int -> bool) (cur_ident: int) 
        get_t_child get_f_child (add_loopsum_node: int * loop_record option -> unit) = (
    let curr_loop = self#get_current_loop in
    let trans_func (_ : bool) = V.Unknown("unused") in
    let try_func (_ : bool) (_ : V.exp) = true in
    let non_try_func (_ : bool) = () in
    let both_fail_func (b : bool) = b in
    let is_in_loop eip = (
      let looprec = ref None in
        Hashtbl.iter (fun h l ->
                        if (l#in_loop eip) && !looprec = None then
                          looprec := Some l
        ) looplist;
        (match !looprec with      
           | Some l -> (
               if !opt_trace_loop_detailed then
                 Printf.eprintf "0x%Lx is in loop\n" eip;
               true)
           | _ -> false)
    )
    in
    let do_check () = (
      let use_loopsum l=
        (let rec get_precond l cur =
           match l with
             | (h, _)::rest -> 
                 (if cur = -1 || not (is_all_seen (get_t_child cur)) then 
                    V.BinOp(V.BITOR, h, (get_precond rest (get_f_child cur)))
                  else 
                    get_precond rest (get_f_child cur)
                 ) 
             | [] -> V.Constant(V.Int(V.REG_1, 0L))
         in
         let random_bit_gen () = 
           let cond = get_precond l (get_t_child cur_ident) in
             if !opt_trace_loopsum_detailed then
               Printf.eprintf "Check all preconds: %s\n" (V.exp_to_string cond);
             if check cond then true
             (* TODO: uncomment the code bellow to enable random decision*)
             (*
              (Printf.eprintf "It is possible to use loopsum\n";
              let rand = random_bit in 
              Printf.eprintf "random: %B\n" rand;
              rand)
              *)
             else false
         in
           add_loopsum_node (cur_ident, self#get_current_loop);
           let res = try_ext trans_func try_func non_try_func random_bit_gen both_fail_func 0x0
           in
             if res then
               Printf.eprintf "Decide to use loopsum\n"
             else Printf.eprintf "Decide not to use loopsum\n";
             res
        )
      in
      let choose_loopsum l =
        let feasible = ref [] in
          List.iteri (fun id h ->
                        let (precond, postcond) = h in
                        (* Currently postcond is a list, but it should only have one element *)
                        (* TODO: only keep one guard for each loopsum*)
                        let (_, vt, eeip) = List.nth postcond 0 in
                          if check precond then feasible := (id, vt, eeip)::!feasible
          ) l;
          let all = List.length !feasible in
            if all <= 0 then failwith "Inconsistency between use_loopsum and choose_loopsum\n";
            let n = Random.int all in
              List.nth !feasible n
      in
      let extend_with_loopsum l id =
        let true_bit () = true in
        let false_bit () = false in
        let rec extend l level =
          match l with
            | h::rest -> 
                (if level < id then
                   (ignore(try_ext trans_func try_func non_try_func false_bit both_fail_func level);
                    extend rest (level+1)
                   )
                 else if level = id then
                   ignore(try_ext trans_func try_func non_try_func true_bit both_fail_func level)
                 else failwith ""
                )
            | [] -> ()
        in
          extend l 1
      in
      let l = self#get_lss in
        if (use_loopsum l) then
          ((match curr_loop with
              | Some loop -> loop#set_status (Some true)
              | _ -> failwith "");
           let (id, vt, eeip) =  choose_loopsum l in
             Printf.eprintf "Choose loopsum[%d]\n" id;
             extend_with_loopsum l (id+1);
             (vt, eeip))
        else 
          ((match curr_loop with
              | Some loop -> loop#set_status (Some false)
              | _ -> failwith "");
           ([], 0L))
    ) 
    in
    let res = 
      (match (is_in_loop eip, self#get_iter) with
         | (true, 2) -> (
             match curr_loop with
               | Some lp ->
                   (match lp#get_status with
                      | Some true -> Printf.eprintf "Loopsum has been applied in 0x%Lx\n" eip; ([], 0L)
                      | Some false -> Printf.eprintf "Loop has been checked but no loopsum applies in 0x%Lx\n" eip; ([], 0L)
                      | _ -> do_check ()
                   )
               | None -> 
                   ignore(try_ext trans_func try_func non_try_func (fun() -> false) both_fail_func 0xffff);
                   (match curr_loop with
                      | Some loop -> 
                          if loop#get_lss != [] then loop#set_status (Some false)
                      | _ -> ());
                   ([], 0L)
           )
         | _ -> ([], 0L)
      ) 
    in
      res
  )

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

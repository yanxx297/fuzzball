(* Parse and comapre the symbolic representations in two files *)
open Stp_external_engine;;
module V = Vine;;
module QE = Query_engine;;

(* File reading function copied from exec_set_options.ml*)
let read_lines_file fname =
  let ic = open_in fname and
	     l = ref [] in
    try
      while true do
	l := (input_line ic) :: !l
      done;
      failwith "Unreachable (infinite loop)"
    with
      | End_of_file ->
	  List.rev !l

let main argv =
  let inputs = ref [] in
    Arg.parse
      (Arg.align (Exec_set_options.cmdline_opts
                  @ Options_linux.linux_cmdline_opts
                  @ State_loader.state_loader_cmdline_opts
                  @ Exec_set_options.concrete_state_cmdline_opts
                  @ Exec_set_options.symbolic_state_cmdline_opts	
                  @ Exec_set_options.concolic_state_cmdline_opts	
                  @ Exec_set_options.explore_cmdline_opts
                  @ Exec_set_options.tags_cmdline_opts
                  @ Exec_set_options.fuzzball_cmdline_opts
                  @ Options_solver.solver_cmdline_opts
                  @ Exec_set_options.influence_cmdline_opts))
      (fun arg -> inputs := arg::!inputs)
      "diff_cpustate filename1 filename2\n";
    (* Handle different variables separately:
     Temporary vars: rename and store in dl; also store connections between variables and its content (exp) in qe_decls
     Symbolic inputs: store in dl with the original name
     Symbolic outputs: store in outputs with the original name
     *)
    let qe = Options_solver.construct_solver "" in
    let dl = ref [] in
    let qe_decls = ref [] in
    let outputs = ref [] in
    let parse_file id fname = 
      let vars = Hashtbl.create 100 in
      let lines = read_lines_file fname in
        List.iteri (fun idx line ->
                     let var = List.hd (String.split_on_char '=' line) in
                     let expr_str = 
                       (if (String.length var) < (String.length line) then
                          String.sub line ((String.length var)+1) ((String.length line)-(String.length var)-1)
                        else "") 
                     in
                       if var.[0] = 't' then                         
                         (let str = String.split_on_char ':' var in
                            assert (List.length str = 2);
                            let varname = List.nth str 0 in
                            let typ = V.type_of_string (String.trim (List.nth str 1)) in
                            let t = V.newvar varname typ in
                              let decl = QE.TempVar(t, (Vine_parser.parse_exp_from_string !dl expr_str)) in 
                                qe_decls := !qe_decls @ [decl];
                                dl := t::!dl;
                         )
                       else if String.sub var 0 3 = "in_" then
                         (let input = V.newvar var V.REG_8 in
                            qe_decls := !qe_decls @ [QE.InputVar(input)];
                            dl := input ::!dl
                         )
                       else if String.sub var 0 4 = "out_" then
                            (Hashtbl.replace vars var (Vine_parser.parse_exp_from_string !dl expr_str); 
                         )
        ) lines;
        outputs := vars::!outputs
    in
      assert (List.length !inputs = 2);
      List.iteri (fun id fname ->
                    parse_file id fname
      ) !inputs;
      let diff_cpustate h1 h2 =        
        let sat = ref "" in
        let unsat = ref "" in
          qe#start_query;
          List.iter (fun decl ->
                       qe#add_decl decl
          ) !qe_decls;
          Hashtbl.iter (fun varname exp1 ->
                          let e = Hashtbl.find_opt h2 varname in
                            match e with
                              | Some exp2 ->
                                  (let cond = V.BinOp(V.EQ, exp1, exp2) in
                                     Printf.printf "%s\n" (V.exp_to_string cond);
                                   let (res, _) = qe#query cond in
                                     match res with
                                       | Some true -> unsat := !unsat^(Printf.sprintf "%s, " varname)
                                       | Some false -> sat := !sat^(Printf.sprintf "%s, " varname)
                                       | None -> Printf.printf "Invalid cond: %s\n" (V.exp_to_string cond)
                                  )
                              | None -> ()
          ) h1;
          qe#after_query true;
          qe#reset;
          Printf.printf "%s are equal\n" !sat;
          Printf.printf "%s are unequal\n" !unsat
      in
        diff_cpustate (List.nth !outputs 0) (List.nth !outputs 1) 
;;

main Sys.argv;;

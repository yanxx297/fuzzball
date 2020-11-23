module DS = Set.Make (Int64);;

let print_loopbody fmt loop_body = 
  Format.fprintf fmt "loopbody size: %d\n" (Hashtbl.length loop_body);
  Hashtbl.iter (fun eip _ ->
                  Format.fprintf fmt "%Lx " eip
  ) loop_body

let print_eip fmt (n: DS.elt) = Format.fprintf fmt "0x%Lx" n

let print_expr fmt expr = Format.fprintf fmt "%s" (Vine.exp_to_string expr)

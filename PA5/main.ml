type var = Var of string
and loc = Loc of int
and fld = Fld of string * loc
and value = Bool of bool
	    | Int of int32
	    | String of string * int (*content, length*)
	    | Object of string * fld list * loc (*type, fields*)
			| Nulldefault of bool

(* Major cool expression types *)
and id= ID of string * string (*id_name, line_number*)
and let_binding = Let_binding of id * id * expr option (*variable, type, init*)
and case_element = Case_element of id * id * expr (*variable, type, body*)
and expr = Assign of id * id * expr * string (*exp_id, var, rhs*)
	   | Dynamic_dispatch of id * expr * id * expr list option * string (*exp_id, e, method, args*)
	   | Static_dispatch of id * expr * id * id * expr list option * string (*exp_id, e, type, method, args*)
	   | Self_dispatch of id * id * expr list option * string (*exp_id, method, args*)
	   | If of id * expr * expr * expr * string (*exp_id, pred, then, else*)
	   | While of id * expr * expr * string (*exp_id, pred, body*)
	   | Block of id * expr list option * string (*exp_id, body*)
	   | New of id * id * string (*exp_id, class name*)
	   | Isvoid of id * expr * string (*exp_id, expression*)
	   | Plus of id * expr * expr * string (*exp_id, lhs, rhs*)
	   | Minus of id * expr * expr * string (*exp_id, lhs, rhs*)
	   | Times of id * expr * expr * string (*exp_id, lhs, rhs*)
	   | Divide of id * expr * expr * string (*exp_id, lhs, rhs*)
	   | Lt of id * expr * expr * string (*exp_id, lhs, rhs*)
	   | Le of id * expr * expr * string (*exp_id, lhs, rhs*)
	   | Eq of id * expr * expr * string (*exp_id, lhs, rhs*)
	   | Not of id * expr * string (*exp_id, expression*)
	   | Negate of id * expr * string (*exp_id, expression*)
	   | Int_exp of id * int32 * string (*exp_id, constant*)
	   | Str_exp of id * string * string (*exp_id, constant*)
	   | ID_exp of id * id * string (*exp_id, id_constant*)
	   | Bool_exp of id * bool * string (*exp_id, constant*)
	   | Let_exp of id * let_binding list * expr * string (*exp_id, bindings, body*)
	   | Case_exp of id * expr * case_element list * string (*exp_id, case_body, elements*)
           | Internal_exp of id * string * string (*exp_id, class.method, return_type*)

(*macro cool structures*)
and formal = Formal of string (*just the name of the formal*)
and feature = Attribute of string * string * expr option (*attribute name, type name, init exp*)
	      | Method of string * string * formal list * expr option (*method name, ultimate parent for def, formals, body*)
and cls = Cls of id * id option * feature list option
and program = Program of cls list
and classmethod = ClassMethod of string * string

let nextloc = ref 1
let newloc origloc = (origloc := !origloc + 1); !origloc

(* stack related stuff useful for stack overflow errors*)
let stack = ref 0
let newstack ostack = (ostack := !ostack + 1); !ostack
let finishstack ostack = (ostack := !ostack - 1); !ostack

(* These maps are the ones from the .cl-type file*)
module ClsMap = Map.Make (String)
module ImpMap = Map.Make (struct type t = classmethod let compare = compare end)
module ParMap = Map.Make (String)

(* These maps are needed for the operational semantics *)
module LocMap = Map.Make (struct type t = loc let compare = compare end)
module EnvMap = Map.Make (struct type t = var let compare = compare end)

(* Basic reading file method *)
let read_file filename =
        let t_map = ref [] in
        let lines = open_in filename in
        try
        while true do
                t_map := input_line lines :: !t_map
        done;
        !t_map
        with End_of_file ->
                close_in lines;
                List.rev !t_map

(* This method is necessary for lessening the amount of List.tl nested methods for getting rid of multiple elements*) 
let rec drop n h = match n with
        0 -> h
      | _ -> drop (n-1) (match h with a::b -> b)

(* helper function for error checks*)
let getlineno exp = match exp with
          Assign (ID (_, num), _, _, _) -> num
	| Dynamic_dispatch (ID (_, num), _, _, _, _) -> num
	| Static_dispatch (ID (_, num), _, _, _, _, _) -> num
	| Self_dispatch (ID (_, num), _, _, _) -> num
	| If (ID (_, num), _, _, _, _) -> num
	| While (ID (_, num), _, _, _) -> num
	| Block (ID (_, num), _, _) -> num
	| New (ID (_, num), _, _) -> num
	| Isvoid (ID (_, num), _, _) -> num
	| Plus (ID (_, num), _, _, _) -> num
	| Minus (ID (_, num), _, _, _) -> num
	| Times (ID (_, num), _, _, _) -> num
	| Divide (ID (_, num), _, _, _) -> num
	| Lt (ID (_, num), _, _, _) -> num
	| Le (ID (_, num), _, _, _) -> num
	| Eq (ID (_, num), _, _, _) -> num
	| Not (ID (_, num), _, _) -> num
	| Negate (ID (_, num), _, _) -> num
	| Int_exp (ID (_, num), _, _) -> num
	| Str_exp (ID (_, num), _, _) -> num
	| ID_exp (ID (_, num), _, _) -> num
	| Bool_exp (ID (_, num), _, _) -> num
	| Let_exp (ID (_, num), _, _, _) -> num
	| Case_exp (ID (_, num), _, _, _) -> num
	| Internal_exp (ID (_, num), _, _) -> num


let rec procExp rest_of_map =
        (* straightforward method that gets the two-line identifier*)
        let procID part_of_map = 
                (ID (List.hd part_of_map, (List.hd (List.tl part_of_map))))
        in
        (* Two types of let bindings:
         * "let_binding_no_init", which is just identifier:type
         * "let_binding_init", which is identifier:type exp, usually assign
         * This simply recursively goes through the let bindings
         * *)
        let proc_let_binds part_of_map =
                let no_lb = int_of_string (List.hd part_of_map) in
                let proc_let_bind one_bind =
                        match one_bind with
                                "let_binding_no_init" :: tl -> let this_name = procID tl in
                                                                let this_type = procID (drop 2 tl) in
                                                                (Let_binding (this_name, this_type, None), drop 4 tl)
                              | "let_binding_init" :: tl -> let this_name = procID tl in
                                                                let this_type = procID (drop 2 tl) in
                                                                let init_exp = procExp (drop 4 tl) in
                                                                (Let_binding (this_name, this_type, Some (fst init_exp)), snd init_exp)
                in
                let rec get_binds let_binds no_binds = match no_binds with
                                                                1 -> let one_bind = proc_let_bind let_binds in
                                                                ([fst one_bind], snd one_bind)
                                                              | _ -> let uno_bind = proc_let_bind let_binds in
                                                                        let other_binds = get_binds (snd uno_bind) (no_binds - 1) in
                                                                        ([fst uno_bind] @ (fst other_binds), snd other_binds)
                in
                get_binds (List.tl part_of_map) no_lb
        in
        (* Case elements are done as ID:Type => exp*)
        let proc_case_eles part_of_map =
                let no_ce = int_of_string (List.hd part_of_map) in
                let proc_one_ce one_case = 
                        let this_name = procID one_case in
                        let this_type = procID (drop 2 one_case) in
                        let rest_exp = procExp (drop 4 one_case) in
                        (Case_element (this_name, this_type, fst rest_exp), snd rest_exp)
                in
                let rec proc_more_ce more_ce no_cases = match no_cases with
                                                                1 -> let fst_case = proc_one_ce more_ce in
                                                                        ([fst fst_case], snd fst_case)
                                                              | _ -> let fst_case = proc_one_ce more_ce in
                                                                        let other_cases = proc_more_ce (snd fst_case) (no_cases - 1) in
                                                                                ([fst fst_case] @ fst other_cases, snd other_cases)
                in
                proc_more_ce (List.tl part_of_map) no_ce
        in
        (* This is primarily for lists of expressions in methods or blocks*)
        let proc_exp_lst part_of_map = let exp_count = int_of_string (List.hd part_of_map) in
                                       match exp_count with 0 -> (None, List.tl part_of_map)
                                                          | _ -> let rec findExpRemain exp exp_count2 = match exp_count2 with 1 -> let fst_exp = procExp exp in
                                                          ([fst fst_exp], snd fst_exp)
                                           | _ -> let fst_exp = procExp exp in
                                           let rest_exp = findExpRemain (snd fst_exp) (exp_count2 - 1) in
                                           ([fst fst_exp] @ (fst rest_exp), snd rest_exp)
                                                          in
                                                          let res = findExpRemain (List.tl part_of_map) exp_count in
                                                          (Some (fst res), snd res)
        in
        (* Individual expressions have individual ways of being written out, as specified in PA4*)
        match rest_of_map with
                no_line :: ret_type :: "assign" :: rest -> let lhs = procID rest in
                                                          let rhs = procExp (drop 2 rest) in
                                                          let exp_id = ID ("assign", no_line) in
                                                          (Assign (exp_id, lhs, fst rhs, ret_type), snd rhs)
             | no_line :: ret_type :: "dynamic_dispatch" :: rest -> let exp_id = ID ("dynamic_dispatch", no_line) in
                                                                    let d_exp = procExp rest in
                                                                    let meth = procID (snd d_exp) in
                                                                    let other_exp = proc_exp_lst(drop 2 (snd d_exp)) in
                                                                    (Dynamic_dispatch (exp_id, fst d_exp, meth, fst other_exp, ret_type), snd other_exp)
             | no_line :: ret_type :: "static_dispatch" :: rest -> let exp_id = ID ("static_dispatch", no_line) in
                                                                   let d_exp = procExp rest in
                                                                   let exp_type = procID (snd d_exp) in
                                                                   let meth = procID(drop 2 (snd d_exp)) in
                                                                   let other_exp = proc_exp_lst (drop 4 (snd d_exp)) in
                                                                   (Static_dispatch (exp_id, fst d_exp, exp_type, meth, fst other_exp, ret_type), snd other_exp)
             | no_line :: ret_type :: "self_dispatch" :: rest -> let exp_id = ID ("self_dispatch", no_line) in
                                                                 let meth = procID rest in
                                                                 let other_exp = proc_exp_lst (drop 2 rest) in
                                                                 (Self_dispatch (exp_id, meth, fst other_exp, ret_type), snd other_exp)
             | no_line :: ret_type :: "if" :: rest -> let exp_id = ID ("if", no_line) in
                                                      let pred_if = procExp rest in
                                                      let then_if = procExp (snd pred_if) in
                                                      let else_if = procExp (snd then_if) in
                                                        (If (exp_id, fst pred_if, fst then_if, fst else_if, ret_type), snd else_if)
             | no_line :: ret_type :: "while" :: rest -> let exp_id = ID("while", no_line) in
                                                         let pred_while = procExp rest in
                                                         let body_while = procExp (snd pred_while) in
                                                           (While (exp_id, fst pred_while, fst body_while, ret_type), snd body_while)
             | no_line :: ret_type :: "block" :: rest -> let exp_id = ID("block", no_line) in
                                                         let block_rest = proc_exp_lst rest in
                                                        (Block (exp_id, fst block_rest, ret_type), snd block_rest)
             | no_line :: ret_type :: "new" :: rest -> let exp_id = ID ("new", no_line) in
                                                       let class_id = procID rest in
                                                        (New (exp_id, class_id, ret_type), drop 2 rest)
             | no_line :: ret_type :: "isvoid" :: rest -> let exp_id = ID ("isvoid", no_line) in
                                                          let void_exp = procExp rest in
                                                                (Isvoid (exp_id, fst void_exp, ret_type), snd void_exp)                
             | no_line :: ret_type :: "plus" :: rest -> let exp_id = ID ("plus", no_line) in
                                                        let lhs_exp = procExp rest in
                                                        let rhs_exp = procExp (snd lhs_exp) in
                                                                (Plus (exp_id, fst lhs_exp, fst rhs_exp, ret_type), snd rhs_exp)
             | no_line :: ret_type :: "minus" :: rest -> let exp_id = ID ("minus", no_line) in
                                                        let lhs_exp = procExp rest in
                                                        let rhs_exp = procExp (snd lhs_exp) in
                                                                (Minus (exp_id, fst lhs_exp, fst rhs_exp, ret_type), snd rhs_exp)
             | no_line :: ret_type :: "times" :: rest -> let exp_id = ID ("times", no_line) in
                                                        let lhs_exp = procExp rest in
                                                        let rhs_exp = procExp (snd lhs_exp) in
                                                                (Times (exp_id, fst lhs_exp, fst rhs_exp, ret_type), snd rhs_exp)
             | no_line :: ret_type :: "divide" :: rest -> let exp_id = ID ("divide", no_line) in
                                                        let lhs_exp = procExp rest in
                                                        let rhs_exp = procExp (snd lhs_exp) in
                                                                (Divide (exp_id, fst lhs_exp, fst rhs_exp, ret_type), snd rhs_exp)
             | no_line :: ret_type :: "lt" :: rest -> let exp_id = ID ("lt", no_line) in
                                                        let lhs_exp = procExp rest in
                                                        let rhs_exp = procExp (snd lhs_exp) in
                                                                (Lt (exp_id, fst lhs_exp, fst rhs_exp, ret_type), snd rhs_exp)
             | no_line :: ret_type :: "le" :: rest -> let exp_id = ID ("le", no_line) in
                                                        let lhs_exp = procExp rest in
                                                        let rhs_exp = procExp (snd lhs_exp) in
                                                                (Le (exp_id, fst lhs_exp, fst rhs_exp, ret_type), snd rhs_exp)
             | no_line :: ret_type :: "eq" :: rest -> let exp_id = ID ("eq", no_line) in
                                                        let lhs_exp = procExp rest in
                                                        let rhs_exp = procExp (snd lhs_exp) in
                                                                (Eq (exp_id, fst lhs_exp, fst rhs_exp, ret_type), snd rhs_exp)
             | no_line :: ret_type :: "not" :: rest -> let exp_id = ID ("not", no_line) in
                                                        let not_exp = procExp rest in
                                                                (Not (exp_id, fst not_exp, ret_type), snd not_exp)
             | no_line :: ret_type :: "negate" :: rest -> let exp_id = ID ("negate", no_line) in
                                                        let negate_exp = procExp rest in
                                                                (Negate (exp_id, fst negate_exp , ret_type), snd negate_exp)
             | no_line :: ret_type :: "integer" :: rest -> let exp_id = ID ("integer", no_line) in
                                                           let const = int_of_string(List.hd rest) in
                                                            (Int_exp (exp_id, Int32.of_int const, ret_type), List.tl rest)
             | no_line :: ret_type :: "string" :: rest -> let exp_id = ID ("string", no_line) in
                                                           let const = List.hd rest in
                                                            (Str_exp (exp_id, const, ret_type), List.tl rest)
             | no_line :: ret_type :: "identifier" :: rest -> let exp_id = ID ("identifier", no_line) in
                                                           let const = procID rest in
                                                            (ID_exp (exp_id, const, ret_type), drop 2 rest)
             | no_line :: ret_type :: "true" :: rest -> let exp_id = ID ("true", no_line) in
                                                            (Bool_exp (exp_id, true, ret_type), rest)
             | no_line :: ret_type :: "false" :: rest -> let exp_id = ID ("false", no_line) in
                                                            (Bool_exp (exp_id, false, ret_type), rest)
             | no_line :: ret_type :: "let" :: rest -> let exp_id = ID ("let", no_line) in
                                                       let bindings = proc_let_binds rest in
                                                       let body = procExp (snd bindings) in
                                                            (Let_exp (exp_id, fst bindings, fst body, ret_type), snd body)
             | no_line :: ret_type :: "case" :: rest -> let exp_id = ID ("case", no_line) in
                                                        let case_exp = procExp rest in
                                                       let eles = proc_case_eles (snd case_exp) in
                                                            (Case_exp (exp_id, fst case_exp, fst eles, ret_type), snd eles)
             | no_line :: ret_type :: "internal" :: rest -> let exp_id = ID ("internal", no_line) in
                                                            let meth = List.hd rest in
                                                                (Internal_exp (exp_id, meth, ret_type), List.tl rest) 

        
(* processing the class map*)
let procClsMap t_map =
        (* 
         * First line = "class_map", hence why it's cut with List.tl
         * Second line = number of classes, hence the head on the cut list
         * *)
        let stuff = List.tl t_map in
        let no_classes = int_of_string (List.hd stuff) in
       (* 
        * For any attribute, there are 3-4 potential lines 
        * If first line is "no_initializer", just return attribute name, type name
        * If first line is "initializer", return attribute name, type name and the initializer expression
        * The tuple is simply a way of keeping track of what has been processed and what is not processed, especially in light of the fact that there is also an implementation map and a parent map
        * *) 
        let rec findAttr attr_list no_attr = match no_attr with
                0 -> ([], attr_list)
                | 1 -> (match attr_list with
                                "no_initializer" :: attr_name :: t_name :: init_exp -> ([Attribute (attr_name, t_name, None)], init_exp)
                                | "initializer" :: attr_name :: t_name :: init_exp -> let init_exp = (procExp (init_exp)) in 
                                                                ([Attribute (attr_name, t_name, Some(fst init_exp))], snd init_exp))
                                | _ -> let attr_hd = findAttr attr_list 1 in
                                                        let other_attr = findAttr (snd attr_hd) (no_attr - 1) in
                                                                ((fst attr_hd) @ (fst other_attr), snd other_attr)
                                                        in
        (* 
         * Each class has a name, number of attributes, then the findAttr kicks in
         * The List.hd (List.tl) stuff is just a neato way of getting the second line
         * the drop 2 method gets rid of two lines to access the third line
         * get_cls_plural is nothing more than a way to store the classes while storing the remains in the second part of the tuple
         * *)
      let get_cls input_l = 
                let name = List.hd input_l in
                let no_attr_in_class = int_of_string (List.hd (List.tl input_l)) in
                let get_attr = findAttr (drop 2 input_l) no_attr_in_class in
                        ((name, fst (get_attr)), snd get_attr)
                in
        let rec get_cls_plural  input_l no_cls = match no_cls with
                                                        1 -> let got_cls = get_cls input_l in
                                                                ([fst got_cls], snd got_cls)
                                                        | _ -> let fst_cls = get_cls input_l in
                                                                let get_more_cls = get_cls_plural (snd fst_cls) (no_cls - 1) in
                                                                        ((fst fst_cls) :: (fst get_more_cls), snd get_more_cls)
        in
        let finished_map = get_cls_plural (List.tl stuff) no_classes in
                let final_map = List.fold_left (fun acc e -> ClsMap.add (fst e) (snd e) acc) ClsMap.empty (fst finished_map) in
                        (final_map, snd finished_map)        


let procImpMap t_map =
        (* Again, ignore the "implementation_map part" *)
        let actual_map = List.tl t_map in
        (* First line is again number of classes*)
        let no_classes = int_of_string(List.hd actual_map) in
        (* formals done recursively *)
        let rec find_formals rest_of_map no_formals = match no_formals with
                  0 -> ([], rest_of_map)
                | 1 -> ([Formal (List.hd rest_of_map)], List.tl rest_of_map)
                | _ -> let rest_of_formals = find_formals (List.tl rest_of_map) (no_formals - 1) in 
                        ((Formal (List.hd rest_of_map))::(fst rest_of_formals), snd rest_of_formals)
        in
        (* the fragment about formals was to lead to the processing of methods*)
        let rec find_methods rest_of_map no_methods = match no_methods with
                  0 -> ([], rest_of_map)
                | 1 -> let meth_name = List.hd rest_of_map in
                        let no_formals = int_of_string (List.hd (List.tl rest_of_map)) in
                        let list_of_formals = find_formals (drop 2 rest_of_map) no_formals in
                        let class_where_def = List.hd (snd list_of_formals) in
                        let meth_body = procExp (List.tl (snd list_of_formals)) in
                        ([Method (meth_name, class_where_def, (fst list_of_formals), Some(fst meth_body))], snd meth_body)
                | _ -> let first_meth = find_methods rest_of_map 1 in
                        let other_meth = find_methods (snd first_meth) (no_methods - 1) in
                        (fst (first_meth) @ fst (other_meth), snd other_meth)
        in
        (* finding methods of one class*)
        let find_one_class_meth part_of_map =
                let cls_name = List.hd part_of_map in
                let no_methods = int_of_string (List.hd (List.tl part_of_map)) in
                let cls_methods = find_methods (drop 2 part_of_map) no_methods in
                        ((cls_name, fst cls_methods), snd(cls_methods))
        in
        (* using statement above, recursively find methods of multiple classes*)
        let rec find_classes_meth part_of_map no_classes = match no_classes with
                1 -> let first_cls = find_one_class_meth part_of_map in
                                ([fst first_cls], snd first_cls)
              | _ -> let first_cls = find_one_class_meth part_of_map in
                        let more_classes = find_classes_meth (snd first_cls) (no_classes - 1) in
                                        (fst (first_cls) :: fst(more_classes), snd more_classes)
        in
        (* This is the list of classes found recursively *)
        let list_classes = find_classes_meth (List.tl actual_map) no_classes in 
        (* The implementation map is classes -> [methods]*)
        let res_map = List.fold_left (fun acc e -> let methele = snd e in
                                                        List.fold_left (fun acc2 e2 -> let methelen = match e2 with
                                                                                        (Method (meth_name, _, _, _)) -> meth_name
                                                        in
                                                        ImpMap.add (ClassMethod (fst e, methelen)) e2 acc2) acc methele) ImpMap.empty (fst list_classes)
        in
        (res_map, snd list_classes)


(* processing parent map *)
let procParMap t_map =
        (* get rid of the unneeded parent_map header *)
        let actual_map = List.tl t_map in
        (* process number of pairs *)
        let no_class_pairs = int_of_string (List.hd actual_map) in
        (* recursively go through pairs *)
        let rec find_pairs pc_map no_pairs = match no_pairs with
                1 -> let c_cls = List.hd pc_map in
                        let p_cls = List.hd (List.tl pc_map) in
                                ([(c_cls, p_cls)], drop 2 pc_map)
              | _ -> let fst_pair = find_pairs pc_map 1 in
                        let other_pairs = find_pairs (snd fst_pair) (no_pairs - 1) in
                                ((fst fst_pair) @ (fst other_pairs), snd other_pairs)
        in
        let all_pairs = find_pairs (List.tl actual_map) no_class_pairs in
        let res_map = List.fold_left (fun acc e -> ParMap.add (fst e) (snd e) acc) ParMap.empty (fst all_pairs) in
        (res_map, snd all_pairs)

 (* eval exp based on operational semantics rules*)
let rec eval_exp so env store cmap imap pmap m_exp = match m_exp with
        Assign (_, var_id, rhs_exp, _) -> let var_name = match var_id with ID (_, name) -> name in
                                        (* e1: v1, s2*)
                                        let (a_val , stores) = eval_exp so env store cmap imap pmap rhs_exp in
                                        (* E(Id) = l_1 *)
                                        let var_loc = EnvMap.find (Var (var_name)) env in
                                        (*S_3 = S_2[v_1/l_1]*)
                                        let store_loc = LocMap.add var_loc a_val stores in
                                        (*return the extra store*)
                                        (a_val, store_loc)
      | Dynamic_dispatch (_, l_exp, meth_id, args, _) -> let update_stack = newstack stack in 
                                                         (* stack is necessary because new object instantiated*)
                                                         (* check for overflow by checking if stack >= 1000 *)
                                                         let chk_overflow = match update_stack < 1000 with
                                                                                false -> let error_l = getlineno m_exp in
                                                                                         let status = Printf.printf("ERROR: %s: Exception: Stack overflow\n") error_l in
                                                                                         let stop_prog = Pervasives.exit(0) in
                                                                                         ""
                                                                              | _ -> "" in
                                                         (* e_n : v_n, S_n+1 up to n+1 arguments*)
                                                         let (meths, storen) = match args with
                                                                                None -> ([], store)
                                                                              | Some (args2) -> List.fold_left (fun acc e -> let (vale, storee) = eval_exp so env (snd acc) cmap imap pmap e in
                                                                                                                             let ovals = fst acc in
                                                                                                                            (ovals @ [vale], storee)) ([], store) args2 in
                                                         (* e_0 : v_0, S_n+2*)
                                                         let (l_exp_cls, storen2) = eval_exp so env storen cmap imap pmap l_exp in
                                                         (* check for dispatch on void
                                                          * Certain variables don't need to worry about being null
                                                          * *)
                                                         let target = match l_exp_cls with
                                                                Bool (_) -> "Bool"
                                                              | Int (_) -> "Int"
                                                              | String (_) -> "String"
                                                              | Object (x, _, _) -> x
                                                              | Nulldefault (_) -> let lineno = getlineno l_exp in
                                                                                   let dispatch_on_void_error = Printf.printf("ERROR: %s: Exception: Dispatch on void error\n") lineno in
                                                                                   let stop_prog = Pervasives.exit(0) in
                                                                                   ""
                                                         in
                                                         
                                                         let meth_name = match meth_id with (ID (_, name)) -> name in
                                                         (* implementation (X, f) = (x_1, ..., x_n, e_{n+1})*)
                                                         let meth_in_map = ImpMap.find (ClassMethod (target, meth_name)) imap in
                                                         (* v_0 = X(a_1 = l_{a_1}, ..., a_m = l_{a_m} *)
                                                         let args_lst = match meth_in_map with (Method (_, _, arg_lst, _)) -> arg_lst in
                                                         (*l_{x_i} = newloc(S_{n+2}), for i = 1...n and each l_{x_i} distinct *)
                                                         let newlocs = List.fold_left (fun acc e -> let currloc = newloc nextloc in
                                                                                 acc @ [Loc(currloc)]) [] args_lst in
                                                         (* S_{n+3} = S_{n+2} [v_1/l_{x_1}, ..., v_n/l_{x_n}*)
                                                         let storen3 = List.fold_left2 (fun acc e1 e2 -> LocMap.add e1 e2 acc) storen2 newlocs meths in
                                                         (* getting the [a_1 : l_{a_1}, ..., a_m : l_{a_m}, x_1 : l_{x_1}, ..., x_n:l_{x_n}] *)
                                                         let meth_env =
                                                              (*Get the list of fields *)
                                                              let fld_lst = List.fold_left2 (fun acc e1 e2 -> let v_fld = match e1 with (Formal (arg_n)) -> arg_n in
                                                                                                acc @ [Fld (v_fld, e2)]) [] args_lst newlocs in
                                                              (*Get the list of attributes *)
                                                              let att_lst = match l_exp_cls with
                                                                                  Object (_, fld_lst, _) -> fld_lst
                                                                                | _ -> [] in
                                                              (*Add fields to environmentmap *)
                                                              let this_map = List.fold_left (fun acc e -> match e with (Fld (att_name, a_loc)) -> EnvMap.add (Var (att_name)) a_loc acc) EnvMap.empty att_lst in
                                                              List.fold_left (fun acc e -> let etuple = match e with Fld (att_name, loc) -> (Var (att_name), loc) in
                                                                                                    EnvMap.add (fst etuple) (snd etuple) acc) this_map fld_lst
                                                         in  
                                                         (*e_{n+1} : v_{n+1}, S_{n+1} *)
                                                         let meth_body = match meth_in_map with (Method (_, _, _, Some(e_body))) -> e_body in
                                                         let retval = eval_exp l_exp_cls meth_env storen3 cmap imap pmap meth_body in
                                                         (*check the stack again *)
                                                         let update_stack_again = finishstack stack in 
                                                                 retval           
      | Static_dispatch (_, l_exp, c_type, meth_id, exps_lst, _) -> let update_stack = newstack stack in 
                                                               (*Check stack for overflow since dispatch requires object to be made *)
                                                               let chk_overflow = match update_stack < 1000 with
                                                                                false -> let error_l = getlineno m_exp in
                                                                                         let status = Printf.printf("ERROR: %s: Exception: Stack overflow\n") error_l in
                                                                                         let stop_prog = Pervasives.exit(0) in
                                                                                         ""
                                                                              | _ -> "" in
                                                               (*e_n : v_n, S_{n+1}, for 1 ... n *)
                                                               let (meths, storen) = match exps_lst with
                                                                                None -> ([], store)
                                                                              | Some (args2) -> List.fold_left (fun acc e -> let (vale, storee) = eval_exp so env (snd acc) cmap imap pmap e in
                                                                                                                             let ovals = fst acc in
                                                                                                                            (ovals @ [vale], storee)) ([], store) args2 in
                                                               (*e_0 : v_0, S_{n+2} *)
                                                               let (l_exp_cls, storen2) = eval_exp so env storen cmap imap pmap l_exp in
                                                               (*Check for dispatch on null object *)
                                                               let target = match l_exp_cls with
                                                                  Bool (_) -> "Bool"
                                                                | Int (_) -> "Int"
                                                                | String (_) -> "String"
                                                                | Object (x, _, _) -> x
                                                                | Nulldefault (_) -> let lineno = getlineno l_exp in
                                                                                   let dispatch_on_void_error = Printf.printf("ERROR: %s: Exception: Dispatch on void error\n") lineno in
                                                                                   let stop_prog = Pervasives.exit(0) in
                                                                                   ""
                                                         in
                                                         (* v_0 = X(a_1 = l_{a_1}, ..., a_m = l_{a_m}) *)
                                                         let targ_cls_name = match c_type with (ID (_, type_n)) -> type_n in
                                                         let meth_name = match meth_id with (ID (_, name)) -> name in
                                                         (*implementation(X, f) = (x_1, ..., x_n, e_{n+1}) *)
                                                         let meth_in_map = ImpMap.find (ClassMethod (targ_cls_name, meth_name)) imap in
                                                         let args_lst = match meth_in_map with (Method (_, _, arg_lst, _)) -> arg_lst in
                                                         (*l_{x_i} = newloc(S_{n+2}, for each i = 1 ... n and each l_{x_i} is distinct *)
                                                         let newlocs = List.fold_left (fun acc e -> let currloc = newloc nextloc in
                                                                                 acc @ [Loc(currloc)]) [] args_lst in
                                                         (* S_{n+3} = S_{n+2} [v_1/l_{x_1}, ..., v_n / l_{x_n} *)
                                                         let storen3 = List.fold_left2 (fun acc e1 e2 -> LocMap.add e1 e2 acc) storen2 newlocs meths in
                                                         (* developing the [a_1:l_{a_1},..., a_m:l_{a_m}, x_1: l_{x_1}, ..., x_n:l_{x_n}] environment *)
                                                         let meth_env =
                                                              (*get the list of fields *)
                                                              let fld_lst = List.fold_left2 (fun acc e1 e2 -> let v_fld = match e1 with (Formal (arg_n)) -> arg_n in
                                                                                                acc @ [Fld (v_fld, e2)]) [] args_lst newlocs in
                                                              (*get the list of attributes*)
                                                              let att_lst = match l_exp_cls with
                                                                                  Object (_, fld_lst, _) -> fld_lst
                                                                                | _ -> [] in
                                                              (* Update the environment *)
                                                              let this_map = List.fold_left (fun acc e -> match e with (Fld (att_name, a_loc)) -> EnvMap.add (Var (att_name)) a_loc acc) EnvMap.empty att_lst in
                                                              List.fold_left (fun acc e -> let etuple = match e with Fld (att_name, loc) -> (Var (att_name), loc) in
                                                                                                    EnvMap.add (fst etuple) (snd etuple) acc) this_map fld_lst
                                                         in  
                                                         (* e_{n+1} : v_{n+1}, S_{n+4} *)
                                                         let meth_body = match meth_in_map with (Method (_, _, _, Some(e_body))) -> e_body in
                                                         let retval = eval_exp l_exp_cls meth_env storen3 cmap imap pmap meth_body in
                                                         let update_stack_again = finishstack stack in 
                                                                 retval  
      | Self_dispatch (_, meth_id, exps_lst, _) -> let updatestack = newstack stack in
                                                   (*Check for overflow as always *)
                                                   let status_code = match updatestack < 1000 with
                                                                                  false -> let lineno = getlineno m_exp in
                                                                                           let self_dispatch_error = Printf.printf("ERROR: %s: Exception: Stack overflow\n") lineno in
                                                                                           let quit_on_error = Pervasives.exit(0) in
                                                                                           ""
                                                                                | true -> ""
                                                   in
                                                   (* e_n: v_n, S_{n+1} *)
                                                   let (meths, storen) = match exps_lst with
                                                                        None -> ([], store)
                                                                      | Some (expss) -> List.fold_left (fun acc e -> let (vale, storee) = eval_exp so env (snd acc) cmap imap pmap e in
                                                                                                                     let ovals = fst acc in
                                                                                                                     (ovals @ [vale], storee)) ([], store) expss in
                                                   (* v_0 = X(a_1 = l_{a_1}, ..., a_m = l_{a_m} *)
                                                   let target = match so with Object (obj_name, _, _) -> obj_name in
                                                   let meth_name = match meth_id with (ID (_, name)) -> name in
                                                   (* implmentation(T, f) = (x_1, ..., x_n, e_{n+1} *)
                                                   let meth_found = ImpMap.find (ClassMethod (target, meth_name)) imap in
                                                   let args_lst = match meth_found with (Method (_, _, argslist, _)) -> argslist in
                                                   (* l_{x_i} = newloc (S_{n+2}) for i = 1... n and each l_{x_i} is distinct *)
                                                   let newlocs = List.fold_left (fun acc e -> let thisloc = newloc nextloc in
                                                                                              acc @ [Loc(thisloc)]) [] args_lst in
                                                   (* S_{n+3} = S_{n+2}[v_1/l_{x_1}, ..., v_n / l_{x_n}] *)
                                                   let morestore = List.fold_left2 (fun acc e1 e2 -> LocMap.add e1 e2 acc) storen newlocs meths in
                                                   (* [a_1:l_{a_1}, ..., a_m: l_{a_m}, x_1: l_{x_1}, ..., x_n:l_{x_n}] environment set up *)
                                                   let meth_env =
                                                           let fld_lst = List.fold_left2 (fun acc e1 e2 -> let v_fld = match e1 with (Formal (arg_n)) -> arg_n in
                                                                                                acc @ [Fld (v_fld, e2)]) [] args_lst newlocs in
                                                           let att_lst = match so with
                                                                                  Object (_, fld_lst, _) -> fld_lst
                                                                                | _ -> [] in
                                                           let this_map = List.fold_left (fun acc e -> match e with (Fld (att_name, a_loc)) -> EnvMap.add (Var (att_name)) a_loc acc) EnvMap.empty att_lst in
                                                           List.fold_left (fun acc e -> let etuple = match e with Fld (att_name, loc) -> (Var (att_name), loc) in
                                                                                                    EnvMap.add (fst etuple) (snd etuple) acc) this_map fld_lst
                                                         in  
                                                   (* e_{n+1} : v_{n+1}, S_{n+4} *)
                                                   let meth_body = match meth_found with (Method (_, _, _, Some(e_body))) -> e_body in
                                                   let retval = eval_exp so meth_env morestore cmap imap pmap meth_body in
                                                   let update_stack_again = finishstack stack in 
                                                                 retval           
      | If (_, pred, then_exp, else_exp, _) -> let (type1, store2) = eval_exp so env store cmap imap pmap pred in
                                                (*e1 : Bool, S_2 *)
                                               (match type1 with
                                                        (* e2: v_2 or e_3:v_3, S_3 depending on whether above is true or false *)
                                                        Bool(true) -> eval_exp so env store2 cmap imap pmap then_exp
                                                      | Bool(false) -> eval_exp so env store2 cmap imap pmap else_exp)
      | While (_, predicate, body, _) as while_exp -> let (predicate_eval, store2) = eval_exp so env store cmap imap pmap predicate in
                (* e_1 : Bool, S_2
                 * if e_1 false, return void, S_2
                 * if e_2 true,
                 * e_2 : v_2, S_3
                 * evaluate full while expression with new store (Store_4)
                 * return void, S_4
                 * *)
             (match predicate_eval with
                  Bool(true) -> let (type2, store3) = eval_exp so env store2 cmap imap pmap body in
                              let (type3, store4) = eval_exp so env store3 cmap imap pmap while_exp in
                                (Nulldefault (false), store4)
                | Bool(false) -> (Nulldefault(true), store2)) 
         (*e_n : v_n, S_{n+1} for all expressions*) 
      | Block (_, exps, _) -> (match exps with Some (expss) -> List.fold_left (fun acc e -> eval_exp so env (snd acc) cmap imap pmap e) (Nulldefault(true), store) expss)
      | New (_, type_n, _) -> let makestack = newstack stack in
                              (*Since new object instantiated stack overflow check *)
                              let call_count = match makestack < 1000 with
                                                false -> let lineno = getlineno m_exp in
                                                         let overflowerror = Printf.printf("ERROR: %s: Exception: stack overflow\n") lineno in
                                                         let quit_after_error = Pervasives.exit(0) in
                                                         ""
                                              | true -> ""
                              in
                              (*T_0 =
                               * X if T = SELF_TYPE and so = X(...)
                               * T otherwise
                               * *)
                              let var_type = match type_n with ID(_, name) -> name in
                              let val_cls = match var_type with
                                        "SELF_TYPE" -> (match so with Object(cls_name, _, _) -> cls_name)
                                      | _ -> var_type
                              in
                              (* class(T_0) = (a_1:T_1 <- e_1, ..., a_n:T_n <- e_n *)
                              let att_lst = ClsMap.find val_cls cmap in
                              (* l_i = newloc (S_1), for i = 1...n and each l_i is distinct *)
                              let newlocs = List.fold_left (fun acc e -> let aloc = newloc nextloc in
                              acc @[Loc(aloc)]) [] att_lst in
                              (*v_1 = T_0(a_1 = l_1,..., a_n=l_n) 
                               * Got fields first for rhs
                               * evaluated v_1 in second line
                               * *)
                              let newfields = List.fold_left2 (fun acc e1 e2 -> let att_name = match e1 with (Attribute(att_n, _, _)) -> att_n in
                                                                                                            acc @ [Fld(att_name, e2)]) [] att_lst newlocs in
                              let newval = (Object (val_cls, newfields, Loc(newloc nextloc))) in
                              (*S_2 = S_1[D_{T_1}/l_1, ..., D_{T_n}/l_n] *)
                              let store2 = List.fold_left2 (fun acc e1 e2 -> let att_type = match e1 with
                                                                                                Attribute(_, t_name, _) -> t_name in
                                                                                                match att_type with
                                                                                                        "Int" -> LocMap.add e2 (Int (Int32.of_int 0)) acc
                                                                                                      | "String" -> LocMap.add e2 (String ("", 0)) acc
                                                                                                      | "Bool" -> LocMap.add e2 (Bool(false)) acc
                                                                                                      | _ -> LocMap.add e2 (Nulldefault (true)) acc) store att_lst newlocs in
                              (* Developing [a_1:l_1,..., a_n:l_n] *)
                              let obj_env = List.fold_left2 (fun acc e1 e2 -> let att_name = match e1 with (Attribute (att_n, _, _)) -> att_n in
                                                                                                          EnvMap.add (Var(att_name)) e2 acc) EnvMap.empty att_lst newlocs in
                              (* {a_1 <- e_1;...;a_n <- e_n;} : v_2, S_3 *)
                              let store3 = List.fold_left2 (fun acc e1 e2 -> match e1 with 
                                                                                (Attribute(_, _, Some(exps))) -> let (eval, nstore) = eval_exp newval obj_env acc cmap imap pmap exps in
                                                                                                                 LocMap.add e2 eval nstore
                                                                              | (Attribute(_, _, None)) -> acc) store2 att_lst newlocs in
                              let finishstackc = finishstack stack in
                              (newval, store3)

      | Isvoid (_, body_exp, _) -> let (e_val, store2) = eval_exp so env store cmap imap pmap body_exp in
      (* e_1 :
              * void, S_2
              * X(...), S_2
              * *)
      (match e_val with
                Nulldefault(_) -> (Bool(true), store2)
              | _ -> (Bool(false), store2))
      (* For all arithmetic operators:
       * e_1: Int(i_1), S_2
       * e_2: Int(i_2), S_3
       * v_1 = Int (i_1 op i_2), where op \in {*, +, -, /}
       * *)
      | Plus (_, lhs, rhs, _) -> let (lhs_val, store2) = eval_exp so env store cmap imap pmap lhs in
                                 let (rhs_val, store3) = eval_exp so env store cmap imap pmap rhs in
                                 (match (lhs_val, rhs_val) with (Int (a), Int(b)) -> (Int (Int32.add a b), store3))
      | Minus (_, lhs, rhs, _) -> let (lhs_val, store2) = eval_exp so env store cmap imap pmap lhs in
                                 let (rhs_val, store3) = eval_exp so env store cmap imap pmap rhs in
                                 (match (lhs_val, rhs_val) with (Int (a), Int(b)) -> (Int (Int32.sub a b), store3))
      | Times (_, lhs, rhs, _) -> let (lhs_val, store2) = eval_exp so env store cmap imap pmap lhs in
                                  let (rhs_val, store3) = eval_exp so env store cmap imap pmap rhs in
                                  (match (lhs_val, rhs_val) with (Int (a), Int(b)) -> (Int (Int32.mul a b), store3)) 
      | Divide (_, lhs, rhs, _) -> let (lhs_val, store2) = eval_exp so env store cmap imap pmap lhs in
                                  let (rhs_val, store3) = eval_exp so env store cmap imap pmap rhs in
                                  (match (lhs_val, rhs_val) with (Int (a), Int(b)) -> match Int32.compare b (Int32.of_int 0) with
                                  (* Division is only arithmetic operation where there is an error case*)
                                          0 -> let line_no = getlineno rhs in
                                                let error = Printf.printf("ERROR: %s: Exception: division by zero\n") line_no in
                                                let exit_ret = Pervasives.exit(0) in
                                                        (Int (Int32.of_int 0), store3) 
                                        | _ -> (Int (Int32.div a b), store3))
      (* For all comparator operations
       * e_1 : Int(i_1), S_2
       * e_2 : Int(i_2), S_3
       * e_1 and e_2 can also deal with booleans (False < True) and Strings (compared with ASCII string ordering)
       * Any other comparison returns false
       * v_1 = 
               * Bool(true), if i_1 op i_2
               * Bool(false), otherwise
       * *)
      | Lt (_, lhs, rhs, _) -> let (lhs_v, store2) = eval_exp so env store cmap imap pmap lhs in
                               let (rhs_v, store3) = eval_exp so env store2 cmap imap pmap rhs in
                               (match (lhs_v, rhs_v) with
                                        (Int(a), Int(b)) -> (match (Int32.compare a b) with
                                                                -1 -> (Bool(true), store3)
                                                              | _ -> (Bool(false), store3))
                                      | (String(a, _), String(b, _)) -> (match (String.compare a b) with
                                                                                -1 -> (Bool(true), store3)
                                                                              | _ -> (Bool (false), store3))
                                      | (Bool(a), Bool(b)) -> (match (a, b) with
                                                                  (false, true) -> (Bool(true), store3)
                                                                | _ -> (Bool(false), store3))
                                      | _ -> (Bool(false), store3))
      | Le (le_id, lhs, rhs, r_type) -> let lt_exp = Lt(le_id, lhs, rhs, r_type) in
                                        let eq_exp = Eq(le_id, lhs, rhs, r_type) in
                                        let (lt_val, store2) = eval_exp so env store cmap imap pmap lt_exp in
                                        let (eq_val, store3) = eval_exp so env store2 cmap imap pmap eq_exp in
                                        (match (lt_val, eq_val) with
                                                (Bool(false), Bool(false)) -> (Bool(false), store3)
                                              | _ -> (Bool(true), store3)) 
      | Eq (_, lhs, rhs, _) -> let (lhs_v, store2) = eval_exp so env store cmap imap pmap lhs in
                               let (rhs_v, store3) = eval_exp so env store2 cmap imap pmap rhs in
                               (match (lhs_v, rhs_v) with
                                        (Int(a), Int(b)) -> (match (Int32.compare a b) with
                                                                  0 -> (Bool(true), store3)
                                                                | _ -> (Bool(false), store3))
                                      | (String(a, _), String(b, _)) -> (match (String.compare a b) with
                                                                                0 -> (Bool(true), store3)
                                                                              | _ -> (Bool(false), store3))
                                      | (Bool(a), Bool(b)) -> (Bool(a=b), store3)
                                      | (Nulldefault(_), Nulldefault(_)) -> (Bool(true), store3)
                                      | (Object(_, _, a), Object(_, _, b)) -> let loc_a = match a with Loc(n) -> n in
                                                                              let loc_b = match b with Loc(n) -> n in
                                                                              (Bool(loc_a=loc_b), store3))
        (* Very straightforward operators that don't need explanation imo *)
      | Not (_, body_exp, _) -> let (e_val, store2) = eval_exp so env store cmap imap pmap body_exp in
        (match e_val with
                Bool(true) -> (Bool(false), store2)
              | _ -> (Bool(true), store2))
      | Negate (_, body_exp, _) -> let (e_val, store2) = eval_exp so env store cmap imap pmap body_exp in
        (match e_val with Int (x) -> (Int (Int32.neg x), store2))
        (* The constants *)
      | Int_exp (_, int_val, _) -> let i_val = Int (int_val) in
        (i_val, store)
      | Str_exp (_, str_val, _) -> let s_val = String (str_val, String.length str_val) in
        (s_val, store)
      | ID_exp (_, var_id, _) -> let var_name = match var_id with
                                                        ID (_, name) -> name in
        (match var_name with
                "self" -> (so, store)
              | _ -> let var_loc = EnvMap.find (Var (var_name)) env in
                        let ret_val = LocMap.find var_loc store in
                                (ret_val, store)) 
      | Bool_exp (_, bool_val, _) -> let b_val = match bool_val with 
                                                        true -> Bool (true)
                                                      | _ -> Bool (false) in
        (b_val, store)
        (* e_1 : v_1, S_2*)
      | Let_exp (_, binds, body, _) -> let (nenv, storen) = List.fold_left (fun acc e -> match e with 
                                                                                        (*If let binding has expression *)
                                                                                        (Let_binding (l_id, type_id, Some(expss))) -> let (type1, out2) = eval_exp so (fst acc) (snd acc) cmap imap pmap expss in
                                                                                        (* l_1 = newloc(S_2)*)
                                                                                        let anotherloc = Loc (newloc nextloc) in
                                                                                        let loc_add = LocMap.add anotherloc type1 out2 in
                                                                                        let var_n = match l_id with (ID (_, name)) -> name in
                                                                                        (*S_3 = S_2[v1/s2] *)
                                                                                        let id_of_l1 = (Var (var_n)) in
                                                                                        (*E' = E[l_1/Id] *)
                                                                                        let env_prime = EnvMap.add id_of_l1 anotherloc (fst acc) in
                                                                                        (env_prime, loc_add)
                                                                                       (*If let binding does not have expression *) 
                                                                                      | (Let_binding (l_id, type_id, None)) -> let type_str = match type_id with (ID (_, type_n)) -> type_n in
                                                                                                                                (* if there is no initializing expression then default must exist*)
                                                                                                                                let set_default = match type_str with
                                                                                                                                                        "Int" -> Int (Int32.of_int 0)
                                                                                                                                                      | "Bool" -> Bool(false)
                                                                                                                                                      | "String" -> String("", 0)
                                                                                                                                                      | _ -> Nulldefault(true)
                                                                                                                                in
                                                                                                                                 let anotherloc = Loc (newloc nextloc) in
                                                                                                                                (*S_3 = S_2[v1/s2] *)
                                                                                                                                let loc_add = LocMap.add anotherloc set_default (snd acc) in
                                                                                                                                let var_n = match l_id with (ID (_, name)) -> name in
                                                                                                                                let id_of_l1 = (Var (var_n)) in
                                                                                                                                (*E' = E[l_1/Id] *)
                                                                                                                                let env_prime = EnvMap.add id_of_l1 anotherloc (fst acc) in
                                                                                                                                (env_prime, loc_add)) (env, store) binds in
                                (* e_2 : v_2, S_4 *) 
                                        eval_exp so nenv storen cmap imap pmap body                                                 

      | Case_exp (_, e0, cases, _) -> let (val0, store2) = eval_exp so env store cmap imap pmap e0 in
                                      (* above is so, e_0 : v_0, S_2 
                                       * Below is a way to turn the class name into a string
                                       * *)
                                      let  cname = match val0 with
                                                        Bool(_) -> "Bool"
                                                      | Int (_) -> "Int"
                                                      | String (_, _) -> "String"
                                                      | Object (x, _, _) -> x
                                                      | Nulldefault (_) -> let lineno = getlineno e0 in
                                                                           let status = Printf.printf("ERROR: %s: Exception: case on void\n") lineno in
                                                                           let exit = Pervasives.exit(0) in
                                                                           ""
                                     in
                                     (* case_classes was simply a way to get the types of the case elements as strings *)
                                     let case_classes = List.fold_left (fun acc e -> let t_id = match e with Case_element (_, tid, _) -> tid in
                                                                                     let t_str = match t_id with ID (_, tstr) -> tstr in
                                                                                     t_str :: acc) [] cases
                                     in
                                     (* finding the closest ancestor of X in {T_1, ..., T_n} *)
                                     let lub compared_str cls_list parmap =
                                             (* Recursively getting the tree
                                              * Base case: the class is of Object type -> derp
                                              * Else: Add the class' parent to the list of classes
                                              * *)
                                             let rec get_inherit_tree curr_cls the_list parmap = match curr_cls with
                                                                                                        "Object" -> the_list @ [curr_cls]
                                                                                                      | _ -> let par_cls = ParMap.find curr_cls parmap in
                                                                                                                get_inherit_tree par_cls (the_list @ [curr_cls]) parmap
                                             in
                                             (* get the inheritance tree from the parent map*)
                                             let inheritstree = get_inherit_tree compared_str [] parmap in
                                             (* return value of the least upper bound *)
                                             let ret_val = List.fold_left (fun acc e -> match acc with
                                                                                              Some (e) -> Some (e)
                                                                                            | None -> (match (List.mem e cls_list) with
                                                                                                                true -> Some(e)
                                                                                                              | false -> None)) None inheritstree
                                             in
                                             (* if the common ancestor exists return it, else return empty string *)
                                             match ret_val with
                                                        Some (str) -> str
                                                      | None -> ""
                                     in
                                     (* check for common ancestor with the branches*)
                                     let b_type = lub cname case_classes pmap in
                                     (* error checking on the branches *)
                                     let test_branches = match b_type with
                                                                "" -> let lineno = getlineno e0 in
                                                                      let status = Printf.printf("ERROR: %s: Exception: no matching branch in case\n") lineno in
                                                                      let exit = Pervasives.exit(0) in
                                                                      ""
                                                              | _ -> ""
                                     in
                                     (* now to actually get the relevant branch *)
                                     let branch = List.hd (List.filter (fun e -> let t_id = match e with Case_element (_, tid, _) -> tid in
                                                                                 let t_str = match t_id with ID (_, tstr) -> tstr in
                                                                                 t_str = b_type) cases) in
                                     (* l_0 = newloc (S_2)*)
                                     let locofval0 = Loc (newloc nextloc) in
                                     (* S_3 = S_2 [v_0/l_0] *)
                                     let store3 = LocMap.add locofval0 val0 store2 in
                                     (* get the variable name and stuff of the value of the case branch itself *)
                                     let var_id = match branch with Case_element (vid, _, _) -> vid in
                                     let v_str = match var_id with ID (_, vstr) -> vstr in
                                     let envprime = EnvMap.add (Var (v_str)) locofval0 env in
                                     (* e_i : v_1, S_4 *)
                                     (match branch with Case_element (_, _, case_exp) -> eval_exp so envprime store3 cmap imap pmap case_exp) 
      | Internal_exp (_, m_name, _) -> let ret_val = match m_name with
                                                        (* Abort just aborts the thing *)
                                                       "Object.abort" -> let status = Printf.printf("abort\n") in
                                                                                (Int (Obj.magic Pervasives.exit(0)), store)
                                                        (* Very straightforward return *)
                                                     | "Object.type_name" -> let cls_name = match so with
                                                                                                Bool (_) -> "Bool"
                                                                                              | Int (_) -> "Int"
                                                                                              | String (_, _) -> "String"
                                                                                              | Object (o_type, _, _) -> o_type in
                                                                (String (cls_name, String.length cls_name), store)
                                                     (* Shallow copy *)
                                                     | "Object.copy" -> let copied = match so with
                                                                                        Bool (b) -> (Bool (b), store)
                                                                                      | Int (i) -> (Int (i), store)
                                                                                      | String (s, l) -> (String (s, l), store)
                                                                                      | Object (o_name, o_meths, _) -> let attr_lst = ClsMap.find o_name cmap in
                                                                                                                        let (cop_lst, n_store) = List.fold_left2 (fun acc e1 e2 -> let v_name = match e1 with Attribute (var_n, _, _) -> var_n in
                                                                                                                        (* After finding class and its attributes, get a new location *)
                                                                                                                        let n_loc = Loc (newloc nextloc) in
                                                                                                                        let acc_store = snd acc in
                                                                                                                        let acc_lst = fst acc in
                                                                                                                        let o_loc = match e2 with Fld (_, loc) -> loc in
                                                                                                                        let o_val = LocMap.find o_loc store in
                                                                                                                        (* new store for new shallow copy *)
                                                                                                                        let update_store = LocMap.add n_loc o_val acc_store in
                                                                                                                        (acc_lst @ [Fld (v_name, n_loc)], update_store)) ([], store) attr_lst o_meths in
                                                      
                                                                                                                        (Object (o_name, cop_lst, Loc(newloc nextloc)), n_store) in
                                                     copied
                                                                                (*find string in environment map and print it out *) 
                                                      | "IO.out_string" -> let ostr_loc = EnvMap.find (Var ("x")) env in
                                                                           let o_str = match LocMap.find ostr_loc store with String (s, _) -> s in
									   let escnline = Str.regexp_string "\\n" in
                                                                           let repnline = Str.global_replace escnline "\n" o_str in
                                                                           let esctab = Str.regexp_string "\\t" in
                                                                           let reptab = Str.global_replace esctab "\t" repnline in
                                                                           let finalstring = print_string reptab in
                                                                                       (so, store)
                                                      (* find the variable needed and print it out *)
                                                      | "IO.out_int" -> let oint_loc = EnvMap.find (Var ("x")) env in
                                                                        let o_int = match LocMap.find oint_loc store with Int (i_val) -> i_val in
                                                                        let action = Printf.printf("%ld") o_int in
                                                                                        (so, store)
                                                      (*read the line *)
                                                      | "IO.in_string" -> let read_str = try read_line () with End_of_file -> "" in
                                                                                (String (read_str, String.length read_str), store)
                                                      | "IO.in_int" -> let read_str = try read_line() with End_of_file -> "" in
                                                                        let start_i = ref 0 in
                                                                        let empt_flag = ref true in
                                                                        for i=1 to String.length read_str do
                                                                                if !empt_flag then
                                                                                        if (String.get read_str (i-1) = ' ') || (String.get read_str (i-1) = '\t') then
                                                                                                start_i := i
                                                                                        else
                                                                                                empt_flag := false
                                                                        done;
                                                                        let max_l = ref 0 in
                                                                        let add_f = ref true in
                                                                        for i=(!start_i + 1) to String.length read_str do
                                                                                let d_ascii = Char.code (String.get read_str (i-1)) in
                                                                                if d_ascii < 48 || d_ascii > 57 then
                                                                                        if i=(!start_i+1) && (String.get read_str (i-1)) = '-' then
                                                                                                max_l := 1
                                                                                        else
                                                                                                add_f := false
                                                                                else
                                                                                        if !add_f then
                                                                                                max_l := !max_l + 1
                                                                        done;
                                                                        let num = try int_of_string (String.sub read_str !start_i !max_l) with Failure "int_of_string" -> 0 in
									
                                                                                (match (num < -2147483648, num > 2147483647) with
                                                                                        (false, false) -> (Int (Int32.of_int num), store)
                                                                                      | (_, _) -> (Int (Int32.of_int 0)), store) 
                                                     (*Since strings stored with length number *)
                                                     | "String.length" -> let str_len = match so with String (_, len) -> len in 
                                                                                        (Int (Int32.of_int str_len), store)
                                                     (* Again simple operation for strings, taking advantage of environment and location map to find the string in question *)
                                                     | "String.concat" -> let var_str_loc = EnvMap.find (Var ("s")) env in
                                                                                let var_s = match LocMap.find var_str_loc store with String (str, _) -> str in
                                                                                let o_s = match so with String (s, _) -> s in
                                                                                (String (o_s ^ var_s, String.length (o_s ^ var_s)), store)
                                                     | "String.substr" -> let o_str = match so with String (s, _) -> s in
                                                                          let i_ind_loc = EnvMap.find (Var ("i")) env in
                                                                          let i_ind = match LocMap.find i_ind_loc store with Int (i_val) -> Int32.to_int i_val in
                                                                          let l_ind_loc = EnvMap.find (Var("l")) env in
                                                                          let l_ind = match LocMap.find l_ind_loc store with Int (i_val) -> Int32.to_int i_val in
                                                                          let max_l = String.length o_str in
                                                                          (* Check for out of bounds exceptions, otherwise pretty simple *)
                                                                          match (i_ind < max_l && i_ind > -1, (i_ind + l_ind - 1) < max_l && l_ind > -1) with 
                                                                                (true, true) -> (String (String.sub o_str i_ind l_ind, l_ind), store)
                                                                              | _ -> let error = Printf.printf("ERROR: 0: Exception: substr out of range\n") in
                                                                                        let exit_action = Pervasives.exit(0) in
                                                                                                (String ("", 0), store)
                                                      in
                                                      ret_val 
                                    
(* initialization of everything before the main method stuff *)
let init_env_store cmap imap pmap =
        (* Initialize stack *)
        let basestack = newstack stack in
        (* Get main class' attributes *)
        let att_lst = match ClsMap.find "Main" cmap with
                        [] -> [Attribute ("", "", None)]
                      | lst -> lst
        in
        (* match locations with fields *)
        let locs = List.fold_left (fun acc e -> let loc1 = (newloc nextloc) in acc @ [Loc (loc1)] ) [] att_lst in
        let flds = List.fold_left2 (fun acc e1 e2 -> let attr_name = match e1 with
        (Attribute (attr_name, _, _)) -> attr_name
        in
        acc @ [Fld (attr_name, e2)]) [] att_lst locs in
        (* vals = self object, consisting of main, fields and its own location *)
        let vals = Object ("Main", flds, Loc (newloc nextloc)) in
        (* Get the default type of each attribute then dump it into location map *)
        let store_locs = List.fold_left2 (fun acc e1 e2 -> let att_type = match e1 with
                                                                        (Attribute (_, t_name, _)) -> t_name in
        match att_type with
                "Int" -> LocMap.add e2 (Int (Int32.of_int 0)) acc
              | "String" -> LocMap.add e2 (String ("", 0)) acc
              | "Bool" -> LocMap.add e2 (Bool (false)) acc
              | _ -> LocMap.add e2 (Nulldefault (true)) acc) LocMap.empty att_lst locs in
        (* Environment map is just the variable to location *)
        let this_env_map = List.fold_left2 (fun acc e1 e2 -> let att_name = match e1 with (Attribute (att_name, _, _)) -> att_name in
        EnvMap.add (Var (att_name)) e2 acc) EnvMap.empty att_lst locs
        in
        let stores = List.fold_left2 (fun acc e1 e2 -> match e1 with
                                                                (Attribute (_, _, None)) -> acc
                                                              | (Attribute (_, _, Some(exp))) -> let (eleval, new_store) = eval_exp vals this_env_map acc cmap imap pmap exp in
                                                              LocMap.add e2 eleval new_store) store_locs att_lst locs in
        let updatestack = finishstack stack in
        (vals, this_env_map, stores)
                                                            
(* Main body of program *)
let () = 
        let type_map = read_file Sys.argv.(1) in
                let (clsmap, rest0) = procClsMap type_map in
                let (impmap, rest1) = procImpMap rest0 in
                let (parmap, rest2) = procParMap rest1 in
                let main_m = ImpMap.find (ClassMethod("Main", "main")) impmap in
                let (self_obj, env, store) = init_env_store clsmap impmap parmap in
                let main_e = match main_m with Method(_, _, _, Some(exp)) -> exp in
                let eval = eval_exp self_obj env store clsmap impmap parmap main_e in
                        match eval with _ -> Pervasives.exit(0)

(**********************************************************************)
(* CertiCoq                                                           *)
(* Copyright (c) 2017                                                 *)
(**********************************************************************)

open Printer
open Metacoq_template_plugin.Ast_quoter
open ExceptionMonad
open AstCommon
open Plugin_utils

(* Taken from Coq's increment_subscript, but works on strings rather than idents *)
let increment_subscript id =
  let len = String.length id in
  let rec add carrypos =
    let c = id.[carrypos] in
    if Util.is_digit c then
      if Int.equal (Char.code c) (Char.code '9') then begin
        assert (carrypos>0);
        add (carrypos-1)
      end
      else begin
        let newid = Bytes.of_string id in
        Bytes.fill newid (carrypos+1) (len-1-carrypos) '0';
        Bytes.set newid carrypos (Char.chr (Char.code c + 1));
        newid
      end
    else begin
      let newid = Bytes.of_string (id^"0") in
      if carrypos < len-1 then begin
        Bytes.fill newid (carrypos+1) (len-1-carrypos) '0';
        Bytes.set newid (carrypos+1) '1'
      end;
      newid
    end
  in String.of_bytes (add (len-1))

let debug_reify = CDebug.create ~name:"certicoq-reify" ()

external get_unboxed_ordinal : Obj.t -> int = "get_unboxed_ordinal" [@@noalloc]

external get_boxed_ordinal : Obj.t -> (int [@untagged]) = "get_boxed_ordinal" "get_boxed_ordinal" [@@noalloc]

(** Various Utils *)

let pr_string s = Pp.str (Caml_bytestring.caml_string_of_bytestring s)

(* remove duplicates but preserve order, keep the leftmost element *)
let nub (xs : 'a list) : 'a list = 
  List.fold_right (fun x xs -> if List.mem x xs then xs else x :: xs) xs []

let rec coq_nat_of_int x =
  match x with
  | 0 -> Datatypes.O
  | n -> Datatypes.S (coq_nat_of_int (pred n))

let debug_msg (flag : bool) (s : string) =
  if flag then
    Feedback.msg_debug (Pp.str s)
  else ()

(* Separate registration of primitive extraction *)

type prim = ((Kernames.kername * Kernames.ident) * bool)
let global_registers = 
  Summary.ref (([], []) : prim list * import list) ~name:"CertiCoq Registration"

let global_registers_name = "certicoq-registration"

let cache_registers (prims, imports) =
  let (prims', imports') = !global_registers in
  global_registers := (prims @ prims', imports @ imports')
let global_registers_input = 
  let open Libobject in 
  declare_object 
    (global_object_nodischarge global_registers_name
    ~cache:(fun r -> cache_registers r)
    ~subst:None) (*(fun (msub, r) -> r)) *)

let register (prims : prim list) (imports : import list) : unit =
  let curlib = Sys.getcwd () in
  let newr = (prims, List.map (fun i -> 
    match i with
    | FromAbsolutePath s -> FromRelativePath (Filename.concat curlib s)
    | _ -> i) imports) in
  (* Feedback.msg_debug Pp.(str"Prims: " ++ prlist_with_sep spc (fun ((x, y), wt) -> str (string_of_bytestring y)) (fst newr)); *)
  Lib.add_leaf (global_registers_input newr)

let get_global_prims () = fst !global_registers
let get_global_includes () = snd !global_registers

(* Support for dynamically-linked certicoq-compiled programs *)
type certicoq_run_function = unit -> Obj.t

let certicoq_run_functions = 
  Summary.ref ~name:"CertiCoq Run Functions Table" 
    (CString.Map.empty : certicoq_run_function CString.Map.t)

let certicoq_run_functions_name = "certicoq-run-functions-registration"

let all_run_functions = ref CString.Set.empty

let cache_certicoq_run_function (s, fn) =
  let fns = !certicoq_run_functions in
  all_run_functions := CString.Set.add s !all_run_functions;
  certicoq_run_functions := CString.Map.add s fn fns

let certicoq_run_function_input = 
  let open Libobject in 
  declare_object 
    (global_object_nodischarge certicoq_run_functions_name
    ~cache:(fun r -> cache_certicoq_run_function r)
    ~subst:None)

let register_certicoq_run s fn =
  Feedback.msg_debug Pp.(str"Registering function " ++ str s ++ str " in certicoq_run");
  Lib.add_leaf (certicoq_run_function_input (s, fn))

let exists_certicoq_run s =
  CString.Map.find_opt s !certicoq_run_functions

let run_certicoq_run s = 
  try CString.Map.find s !certicoq_run_functions
  with Not_found -> CErrors.user_err Pp.(str"Could not find certicoq run function associated to " ++ str s)

(** Coq FFI: message channels and raising user errors. *)

let coq_msg_info s =
  let s = Caml_bytestring.caml_string_of_bytestring s in
  Feedback.msg_info (Pp.str s)
  
let _ = Callback.register "coq_msg_info" coq_msg_info

let coq_msg_debug s = 
  Feedback.msg_debug Pp.(str (Caml_bytestring.caml_string_of_bytestring s))
  
let _ = Callback.register "coq_msg_debug" coq_msg_debug

let coq_msg_notice s = 
  Feedback.msg_notice Pp.(str (Caml_bytestring.caml_string_of_bytestring s))
  
let _ = Callback.register "coq_msg_notice" coq_msg_notice
  
let coq_user_error s =
  CErrors.user_err Pp.(str (Caml_bytestring.caml_string_of_bytestring s))

let _ = Callback.register "coq_user_error" coq_user_error 

(** Compilation Command Arguments *)

type command_args =
 | BYPASS_QED
 | CPS
 | TIME
 | TIMEANF
 | OPT of int
 | DEBUG
 | ARGS of int
 | ANFCONFIG of int (* To measure different ANF configurations *)
 | BUILDDIR of string (* Directory name to be prepended to the file name *)
 | EXT of string (* Filename extension to be appended to the file name *)
 | DEV of int    (* For development purposes *)
 | PREFIX of string (* Prefix to add to the generated FFI fns, avoids clashes with C fns *)
 | TOPLEVEL_NAME of string (* Name of the toplevel function ("body" by default) *)
 | FILENAME of string (* Name of the generated file *)

type options =
  { bypass_qed : bool;
    cps       : bool;
    time      : bool;
    time_anf  : bool;
    olevel    : int;
    debug     : bool;
    args      : int;
    anf_conf  : int;
    build_dir : string;
    filename  : string;
    ext       : string;
    dev       : int;
    prefix    : string;
    toplevel_name : string;
    prims     : ((Kernames.kername * Kernames.ident) * bool) list;
  }

let default_options : options =
  { bypass_qed = false;
    cps       = false;
    time      = false;
    time_anf  = false;
    olevel    = 1;
    debug     = false;
    args      = 5;
    anf_conf  = 0;
    build_dir = ".";
    filename  = "";
    ext       = "";
    dev       = 0;
    prefix    = "";
    toplevel_name = "body";
    prims     = [];
  }

let check_build_dir d =
  if d = "" then "." else
  let isdir = 
    try Unix.((stat d).st_kind = S_DIR)
    with Unix.Unix_error (Unix.ENOENT, _, _) ->
      CErrors.user_err Pp.(str "Could not compile: build directory " ++ str d ++ str " not found.")
  in
  if not isdir then 
    CErrors.user_err Pp.(str "Could not compile: " ++ str d ++ str " is not a directory.")
  else d

let make_options (l : command_args list) (pr : ((Kernames.kername * Kernames.ident) * bool) list) (fname : string) : options =
  let rec aux (o : options) l =
    match l with
    | [] -> o
    | BYPASS_QED :: xs -> aux {o with bypass_qed = true} xs
    | CPS      :: xs -> aux {o with cps = true} xs
    | TIME     :: xs -> aux {o with time = true} xs
    | TIMEANF  :: xs -> aux {o with time_anf = true} xs
    | OPT n    :: xs -> aux {o with olevel = n} xs
    | DEBUG    :: xs -> aux {o with debug = true} xs
    | ARGS n   :: xs -> aux {o with args = n} xs
    | ANFCONFIG n :: xs -> aux {o with anf_conf = n} xs
    | BUILDDIR s  :: xs ->
      let s = check_build_dir s in
      aux {o with build_dir = s} xs
    | EXT s    :: xs -> aux {o with ext = s} xs
    | DEV n    :: xs -> aux {o with dev = n} xs
    | PREFIX s :: xs -> aux {o with prefix = s} xs
    | TOPLEVEL_NAME s :: xs -> aux {o with toplevel_name = s} xs
    | FILENAME s :: xs -> aux {o with filename = s} xs
  in
  let opts = { default_options with filename = fname } in
  let o = aux opts l in
  {o with prims = pr}

let make_pipeline_options (opts : options) =
  let cps    = opts.cps in
  let args = coq_nat_of_int opts.args in
  let olevel = coq_nat_of_int opts.olevel in
  let timing = opts.time in
  let timing_anf = opts.time_anf in
  let debug  = opts.debug in
  let anfc = coq_nat_of_int opts.anf_conf in
  let dev = coq_nat_of_int opts.dev in
  let prefix = bytestring_of_string opts.prefix in
  let toplevel_name = bytestring_of_string opts.toplevel_name in
  let prims = get_global_prims () @ opts.prims in
  (* Feedback.msg_debug Pp.(str"Prims: " ++ prlist_with_sep spc (fun ((x, y), wt) -> str (string_of_bytestring y)) prims); *)
  Pipeline.make_opts cps args anfc olevel timing timing_anf debug dev prefix toplevel_name prims

(** Main Compilation Functions *)

(* Get fully qualified name of a constant *)
let get_name (gr : Names.GlobRef.t) : string =
  match gr with
  | Names.GlobRef.ConstRef c -> Names.KerName.to_string (Names.Constant.canonical c)
  | _ -> CErrors.user_err Pp.(Printer.pr_global gr ++ str " is not a constant definition")


(* Quote Coq term *)
let quote_term opts env sigma c =
  let debug = opts.debug in
  let bypass = opts.bypass_qed in
  debug_msg debug "Quoting";
  let time = Unix.gettimeofday() in
  let term = Metacoq_template_plugin.Ast_quoter.quote_term_rec ~bypass env sigma (EConstr.to_constr sigma c) in
  let time = (Unix.gettimeofday() -. time) in
  debug_msg debug (Printf.sprintf "Finished quoting in %f s.. compiling to L7." time);
  term

let quote opts gr =
  let env = Global.env () in
  let sigma = Evd.from_env env in
  let sigma, c = Evd.fresh_global env sigma gr in
  quote_term opts env sigma c

(* Compile Quoted term with CertiCoq *)

module type CompilerInterface = sig
  type name_env
  val compile : Pipeline_utils.coq_Options -> Ast0.Env.program -> ((name_env * Clight.program) * Clight.program) CompM.error * Bytestring.String.t
  val printProg : Clight.program -> name_env -> string -> import list -> unit

  val generate_glue : Pipeline_utils.coq_Options -> Ast0.Env.global_declarations -> 
    (((name_env * Clight.program) * Clight.program) * Bytestring.String.t list) CompM.error
  
  val generate_ffi :
    Pipeline_utils.coq_Options -> Ast0.Env.program -> (((name_env * Clight.program) * Clight.program) * Bytestring.String.t list) CompM.error
  
end

module MLCompiler : CompilerInterface with 
  type name_env = BasicAst.name Cps.M.t
  = struct
  type name_env = BasicAst.name Cps.M.t
  let compile = Pipeline.compile
  let printProg prog names (dest : string) (imports : import list) =
    let imports' = List.map (fun i -> match i with
      | FromRelativePath s -> "#include \"" ^ s ^ "\""
      | FromLibrary s -> "#include <" ^ s ^ ">"
      | FromAbsolutePath s ->
          failwith "Import with absolute path should have been filled") imports in
    PrintClight.print_dest_names_imports prog (Cps.M.elements names) dest imports'
  let generate_glue = Glue.generate_glue
  let generate_ffi = Ffi.generate_ffi
end


module CompileFunctor (CI : CompilerInterface) = struct

  let make_fname opts str =
    Filename.concat opts.build_dir str

  let compile opts term imports =
    let debug = opts.debug in
    let options = make_pipeline_options opts in
    let runtime_imports = [FromLibrary (if opts.cps then "gc.h" else "gc_stack.h")] in
    let curlib = Sys.getcwd () in
    let imports = List.map (fun i -> 
      match i with
      | FromAbsolutePath s -> FromRelativePath (Filename.concat curlib s)
      | _ -> i) imports in
    let imports = runtime_imports @ get_global_includes () @ imports in
    let p = CI.compile options term in
    match p with
    | (CompM.Ret ((nenv, header), prg), dbg) ->
      debug_msg debug "Finished compiling, printing to file.";
      let time = Unix.gettimeofday() in
      let fname = opts.filename in
      let suff = opts.ext in
      let cstr = fname ^ suff ^ ".c" in
      let hstr = fname ^ suff ^ ".h" in
      let cstr' = make_fname opts cstr in
      let hstr' = make_fname opts hstr in
      CI.printProg prg nenv cstr' (imports @ [FromRelativePath hstr]);
      CI.printProg header nenv hstr' (runtime_imports);

      (* let cstr = Metacoq_template_plugin.Tm_util.string_to_list (Names.KerName.to_string (Names.Constant.canonical const) ^ suff ^ ".c") in
      * let hstr = Metacoq_template_plugin.Tm_util.string_to_list (Names.KerName.to_string (Names.Constant.canonical const) ^ suff ^ ".h") in
      * Pipeline.printProg (nenv,prg) cstr;
      * Pipeline.printProg (nenv,header) hstr; *)
      let time = (Unix.gettimeofday() -. time) in
      debug_msg debug (Printf.sprintf "Printed to file %s in %f s.." cstr' time);
      debug_msg debug "Pipeline debug:";
      debug_msg debug (string_of_bytestring dbg)
    | (CompM.Err s, dbg) ->
      debug_msg debug "Pipeline debug:";
      debug_msg debug (string_of_bytestring dbg);
      CErrors.user_err Pp.(str "Could not compile: " ++ (pr_string s) ++ str "\n")


  (* Generate glue code for the compiled program *)
  let generate_glue (standalone : bool) opts globs =
    if standalone && opts.filename = "" then
      CErrors.user_err Pp.(str "You need to provide a file name with the -file option.")
    else
    let debug = opts.debug in
    let options = make_pipeline_options opts in
    let runtime_imports = 
      [ FromLibrary (if opts.cps then "gc.h" else "gc_stack.h"); FromLibrary "stdio.h" ] in
    let time = Unix.gettimeofday() in
    (match CI.generate_glue options globs with
    | CompM.Ret (((nenv, header), prg), logs) ->
      let time = (Unix.gettimeofday() -. time) in
      debug_msg debug (Printf.sprintf "Generated glue code in %f s.." time);
      (match logs with [] -> () | _ ->
        debug_msg debug (Printf.sprintf "Logs:\n%s" (String.concat "\n" (List.map string_of_bytestring logs))));
      let time = Unix.gettimeofday() in
      let suff = opts.ext in
      let fname = opts.filename in
      let cstr = if standalone then fname ^ ".c" else "glue." ^ fname ^ suff ^ ".c" in
      let hstr = if standalone then fname ^ ".h" else "glue." ^ fname ^ suff ^ ".h" in
      let cstr' = make_fname opts cstr in
      let hstr' = make_fname opts hstr in
      CI.printProg prg nenv cstr' (runtime_imports @ [FromRelativePath hstr]);
      CI.printProg header nenv hstr' runtime_imports;

      let time = (Unix.gettimeofday() -. time) in
      debug_msg debug (Printf.sprintf "Printed glue code to file %s in %f s.." cstr time)
    | CompM.Err s ->
      CErrors.user_err Pp.(str "Could not generate glue code: " ++ pr_string s))

  let compile_only (opts : options) (gr : Names.GlobRef.t) (imports : import list) : unit =
    let term = quote opts gr in
    compile opts (Obj.magic term) imports

  let generate_glue_only opts gr =
    let term = quote opts gr in
    generate_glue true opts (Ast0.Env.declarations (fst (Obj.magic term)))
    
  let find_executable debug cmd = 
    let whichcmd = Unix.open_process_in cmd in
    let result = 
      try Stdlib.input_line whichcmd 
      with End_of_file -> ""
    in
    let status = Unix.close_process_in whichcmd in
    match status with
    | Unix.WEXITED 0 -> 
      if debug then Feedback.msg_debug Pp.(str "Compiler is " ++ str result);
      result
    | _ -> failwith "Compiler not found"

  let compiler_executable debug = find_executable debug "which gcc || which clang-11"
  
  type line = 
    | EOF
    | Info of string
    | Error of string

  let read_line stdout stderr =
    try Info (input_line stdout)
    with End_of_file -> 
      try Error (input_line stderr)
      with End_of_file -> EOF
  
  let run_program debug prog =
    let (stdout, stdin, stderr) = Unix.open_process_full ("./" ^ prog) (Unix.environment ()) in
    let continue = ref true in
    while !continue do 
      match read_line stdout stderr with
      | EOF -> debug_msg debug ("Program terminated"); continue := false
      | Info s -> Feedback.msg_notice Pp.(str prog ++ str": " ++ str s)
      | Error s -> Feedback.msg_warning Pp.(str prog ++ str": " ++ str s)
    done

  let runtime_dir () = 
    let open Boot in
    let env = Env.init () in
    Path.relative (Path.relative (Path.relative (Env.user_contrib env) "CertiCoq") "Plugin") "runtime"

  let make_rt_file na =
    Boot.Env.Path.(to_string (relative (runtime_dir ()) na))

  let compile_C opts gr imports =
    let () = compile_only opts gr imports in
    let imports = get_global_includes () @ imports in
    let debug = opts.debug in
    let fname = opts.filename in
    let suff = opts.ext in
    let name = make_fname opts (fname ^ suff) in
    let compiler = compiler_executable debug in
    let rt_dir = runtime_dir () in
    let cmd =
        Printf.sprintf "%s -Wno-everything -g -I %s -I %s -c -o %s %s" 
          compiler opts.build_dir (Boot.Env.Path.to_string rt_dir) (name ^ ".o") (name ^ ".c") 
    in
    let importso =
      let oname s = 
        assert (CString.is_suffix ".h" s);
        String.sub s 0 (String.length s - 2) ^ ".o"
      in 
      let imports' = List.concat (List.map (fun i -> 
        match i with 
        | FromAbsolutePath s -> [oname s]
        | FromRelativePath s -> [oname s]
        | FromLibrary s -> [make_rt_file (oname s)]) imports) in
      let l = make_rt_file "certicoq_run_main.o" :: imports' in
      String.concat " " l
    in
    let gc_stack_o = make_rt_file "gc_stack.o" in
    debug_msg debug (Printf.sprintf "Executing command: %s" cmd);
    match Unix.system cmd with
    | Unix.WEXITED 0 -> 
      let linkcmd =
        Printf.sprintf "%s -Wno-everything -g -L %s -L %s -o %s %s %s %s" 
          compiler opts.build_dir (Boot.Env.Path.to_string rt_dir) name gc_stack_o (name ^ ".o") importso
      in
      debug_msg debug (Printf.sprintf "Executing command: %s" linkcmd);
      (match Unix.system linkcmd with
      | Unix.WEXITED 0 ->
          debug_msg debug (Printf.sprintf "Compilation ran fine, running %s" name);
          run_program debug name
      | Unix.WEXITED n -> CErrors.user_err Pp.(str"Compiler exited with code " ++ int n ++ str" while running " ++ str linkcmd)
      | Unix.WSIGNALED n | Unix.WSTOPPED n -> CErrors.user_err Pp.(str"Compiler was signaled with code " ++ int n))
    | Unix.WEXITED n -> CErrors.user_err Pp.(str"Compiler exited with code " ++ int n ++ str" while running " ++ str cmd)
    | Unix.WSIGNALED n | Unix.WSTOPPED n -> CErrors.user_err Pp.(str"Compiler was signaled with code " ++ int n  ++ str" while running " ++ str cmd)
  

  let ocamlfind_executable _debug = 
    "_opam/bin/ocamlfind"
    (* find_executable debug "which ocamlfind"  *)

  type reifyable_type =
  | IsInductive of Names.inductive * Univ.Instance.t * Constr.t list
  | IsPrimitive of Names.Constant.t * Univ.Instance.t * Constr.t list
  
  let type_of_reifyable_type = function
    | IsInductive (hd, u, args) -> Term.applistc (Constr.mkIndU ((hd, u))) args
    | IsPrimitive (c, u, args) -> Term.applistc (Constr.mkConstU ((c, u))) args
  
  let pr_reifyable_type env sigma ty =
    Printer.pr_constr_env env sigma (type_of_reifyable_type ty)

  let find_nth_constant n ar =
    let open Inductiveops in
    let rec aux i const = 
      if Array.length ar <= i then raise Not_found
      else if CList.is_empty ar.(i).cs_args then  (* FIXME lets in constructors *)
        if const = n then i 
        else aux (i + 1) (const + 1)
      else aux (i + 1) const
    in aux 0 0
  
  let find_nth_non_constant n ar =
    let open Inductiveops in
    let rec aux i nconst = 
      if Array.length ar <= i then raise Not_found
      else if not (CList.is_empty ar.(i).cs_args) then 
        if nconst = n then i 
        else aux (i + 1) (nconst + 1)
      else aux (i + 1) nconst
    in aux 0 0

  let check_reifyable env sigma ty =
    (* We might have bound universes though. It's fine! *)
    try let (hd, u), args = Inductiveops.find_inductive env sigma ty in
      IsInductive (hd, EConstr.EInstance.kind sigma u, args)
    with Not_found -> 
      let hnf = Reductionops.whd_all env sigma ty in
      let hd, args = EConstr.decompose_app sigma hnf in
      match EConstr.kind sigma hd with
      | Const (c, u) when Environ.is_primitive_type env c -> 
        IsPrimitive (c, EConstr.EInstance.kind sigma u, List.map EConstr.Unsafe.to_constr args)
      | _ -> CErrors.user_err 
        Pp.(str"Cannot reify values of non-inductive or non-primitive type: " ++ 
          Printer.pr_econstr_env env sigma ty)

  let ill_formed env sigma ty =
    match ty with
    | IsInductive _ -> 
      CErrors.anomaly ~label:"certicoq-reify-ill-formed"
      Pp.(str "Ill-formed inductive value representation in CertiCoq's reification for type " ++
        pr_reifyable_type env sigma ty)
    | IsPrimitive _ ->
      CErrors.anomaly ~label:"certicoq-reify-ill-formed"
      Pp.(str "Ill-formed primitive value representation in CertiCoq's reification for type " ++
        pr_reifyable_type env sigma ty)

  let ocaml_get_boxed_ordinal v = 
    (* tag is the header of the object *)
    let tag = Array.unsafe_get (Obj.magic v : Obj.t array) (-1) in
    (* We turn it into an ocaml int usable for arithmetic operations *)
    let tag_int = (Stdlib.Int.shift_left (Obj.magic (Obj.repr tag)) 1) + 1 in
    Feedback.msg_debug (Pp.str (Printf.sprintf "Ocaml tag: %i" (Obj.tag tag)));
    Feedback.msg_debug (Pp.str (Printf.sprintf "Ocaml get_boxed_ordinal int: %u" tag_int));
    Feedback.msg_debug (Pp.str (Printf.sprintf "Ocaml get_boxed_ordinal ordinal: %u" (tag_int land 255)));
    tag_int land 255

  let reify env sigma ty v : Constr.t = 
    let open Declarations in
    let debug s = debug_reify Pp.(fun () -> str s) in
    let rec aux ty v =
    match ty with
    | IsInductive (hd, u, args) -> 
      let open Inductive in
      let open Inductiveops in
      let spec = lookup_mind_specif env hd in
      let indfam = make_ind_family ((hd, u), args) in
      let npars = inductive_params spec in
      let params, _indices = CList.chop npars args in
      let cstrs = get_constructors env indfam in
      let () = debug (Printf.sprintf "Reifying inductive value") in
      if Obj.is_block v then
        let () = debug (Printf.sprintf "Reifying constructor block") in
        let ord = get_boxed_ordinal v in
        let ord' = ocaml_get_boxed_ordinal v in
        let () = if ord == ord' then () else 
          Feedback.msg_debug (Pp.str (Printf.sprintf "C get_boxed_ordinal = %i, OCaml get_boxed_ordinale = %i" ord ord'))
        in
        let () = debug (Printf.sprintf "Reifying constructor block of tag %i" ord) in
        let coqidx = 
          try find_nth_non_constant ord cstrs 
          with Not_found -> ill_formed env sigma ty
        in
        let cstr = cstrs.(coqidx) in
        let ctx = Vars.smash_rel_context cstr.cs_args in
        let vargs = List.init (List.length ctx) (Obj.field v) in
        let args' = List.map2 (fun decl v -> 
          let argty = check_reifyable env sigma 
          (EConstr.of_constr (Context.Rel.Declaration.get_type decl)) in
          aux argty v) (List.rev ctx) vargs in
        Term.applistc (Constr.mkConstructU ((hd, coqidx + 1), u)) (params @ args')
      else (* Constant constructor *)
        let () = debug (Printf.sprintf "Reifying constant constructor") in
        let ord = (Obj.magic v : int) in
        let () = debug (Printf.sprintf "Reifying constant constructor: %i" ord) in
        let coqidx = 
          try find_nth_constant ord cstrs 
          with Not_found -> ill_formed env sigma ty 
        in
        let () = debug (Printf.sprintf "Reifying constant constructor: %i is %i in Coq" ord coqidx) in
        Term.applistc (Constr.mkConstructU ((hd, coqidx + 1), u)) params
    | IsPrimitive (c, u, _args) -> 
      if Environ.is_array_type env c then 
        CErrors.user_err Pp.(str "Primitive arrays are not supported yet")
      else if Environ.is_float64_type env c then
        Constr.mkFloat (Obj.magic v)
      else if Environ.is_int63_type env c then
        Constr.mkInt (Obj.magic v)
      else CErrors.user_err Pp.(str "Unsupported primitive type")
    in aux ty v

  let template name = 
    Printf.sprintf "\nvalue %s ()\n { struct thread_info* tinfo = make_tinfo(); return %s_body(tinfo); }\n" name name
  let template_header name = 
    Printf.sprintf "#include <gc_stack.h>\nextern value %s ();\n" name

  let write_c_driver opts name = 
    let fname = make_fname opts (opts.filename ^ ".c") in
    let fhname = make_fname opts (opts.filename ^ ".h") in
    let fd = Unix.(openfile fname [O_CREAT; O_APPEND; O_WRONLY] 0o640) in
    let chan = Unix.out_channel_of_descr fd in
    output_string chan (template name);
    flush chan;
    close_out chan;
    let chan = open_out fhname in
    output_string chan (template_header name);
    flush chan; close_out chan;
    fname
  
  let template_ocaml name = 
    Printf.sprintf "external %s : unit -> Obj.t = \"%s\"\nlet _ = Certicoq_plugin.Certicoq.register_certicoq_run \"%s\" (Obj.magic %s)" name name name name
  
  let write_ocaml_driver opts name = 
    let fname = make_fname opts (opts.filename ^ "_wrapper.ml") in
    let chan = open_out fname in
    output_string chan (template_ocaml name);
    flush chan; close_out chan; fname


  let time ~(msg:Pp.t) f =
    let start = Unix.gettimeofday() in
    let res = f () in
    let time = Unix.gettimeofday () -. start in
    Feedback.msg_notice Pp.(msg ++ str (Printf.sprintf " executed in %f sec" time));
    res

  let certicoq_eval_named opts env sigma id c imports =
    let prog = quote_term opts env sigma c in
    let tyinfo = 
      let ty = Retyping.get_type_of env sigma c in
      (* assert (Evd.is_empty sigma); *)
      check_reifyable env sigma ty
    in
    let () = compile opts (Obj.magic prog) imports in
    (* Write wrapping code *)
    let c_driver = write_c_driver opts id in
    let ocaml_driver = write_ocaml_driver opts id in      
    let imports = get_global_includes () @ imports in
    let debug = opts.debug in
    let suff = opts.ext in
    let name = make_fname opts (id ^ suff) in
    let compiler = compiler_executable debug in
    let ocamlfind = ocamlfind_executable debug in
    let rt_dir = runtime_dir () in

    let cmd =
        Printf.sprintf "%s -Wno-everything -g -I %s -I %s -c -o %s %s" 
          compiler opts.build_dir (Boot.Env.Path.to_string rt_dir) (Filename.remove_extension c_driver ^ ".o") c_driver
    in
    let importso =
      let oname s = 
        assert (CString.is_suffix ".h" s);
        String.sub s 0 (String.length s - 2) ^ ".o"
      in 
      let imports' = List.concat (List.map (fun i -> 
        match i with 
        | FromAbsolutePath s -> [oname s]
        | FromRelativePath s -> [oname s]
        | FromLibrary s -> [make_rt_file (oname s)]) imports) in
      let l = imports' in
      String.concat " " l
    in
    let gc_stack_o = make_rt_file "gc_stack.o" in
    debug_msg debug (Printf.sprintf "Executing command: %s" cmd);
    let packages = ["coq-core"; "coq-core.plugins.ltac"; "coq-metacoq-template-ocaml"; 
      "coq-core.interp"; "coq-core.kernel"; "coq-core.library"] in
    let pkgs = String.concat "," packages in
    let dontlink = "str,unix,dynlink,threads,zarith,coq-core,coq-core.plugins.ltac,coq-core.interp" in
    match Unix.system cmd with
    | Unix.WEXITED 0 ->
      let shared_lib = name ^ ".cmxs" in
      let linkcmd =
        Printf.sprintf "%s ocamlopt -shared -linkpkg -dontlink %s -thread -rectypes -package %s \
        -I %s -I plugin -o %s %s %s %s %s"
        ocamlfind dontlink pkgs opts.build_dir shared_lib ocaml_driver gc_stack_o 
        (make_fname opts opts.filename ^ ".o") importso
      in
      debug_msg debug (Printf.sprintf "Executing command: %s" linkcmd);
      (match Unix.system linkcmd with
      | Unix.WEXITED 0 ->
          debug_msg debug (Printf.sprintf "Compilation ran fine, linking compiled code for %s" id);
          Dynlink.loadfile_private shared_lib;
          debug_msg debug (Printf.sprintf "Dynamic linking succeeded, retrieving function %s" id);
          let result = 
            if opts.time then time ~msg:(Pp.str id) (run_certicoq_run id)
            else run_certicoq_run id ()
          in
          debug_msg debug (Printf.sprintf "Running the dynamic linked program succeeded, reifying result");
          if opts.time then time ~msg:(Pp.str "reification") (fun () -> reify env sigma tyinfo result)
          else reify env sigma tyinfo result
      | Unix.WEXITED n -> CErrors.user_err Pp.(str"Compiler exited with code " ++ int n ++ str" while running " ++ str linkcmd)
      | Unix.WSIGNALED n | Unix.WSTOPPED n -> CErrors.user_err Pp.(str"Compiler was signaled with code " ++ int n))
    | Unix.WEXITED n -> CErrors.user_err Pp.(str"Compiler exited with code " ++ int n ++ str" while running " ++ str cmd)
    | Unix.WSIGNALED n | Unix.WSTOPPED n -> CErrors.user_err Pp.(str"Compiler was signaled with code " ++ int n  ++ str" while running " ++ str cmd)

  let next_string_away_from s bad =
    let rec name_rec s = if bad s then name_rec (increment_subscript s) else s in
    name_rec s
  
  let find_fresh s map = 
    Feedback.msg_debug Pp.(str "Looking for fresh " ++ str s ++ str " in " ++ prlist_with_sep spc str (CString.Set.elements map));
    let freshs = next_string_away_from s (fun s -> CString.Set.mem s map) in
    Feedback.msg_debug Pp.(str "Found " ++ str freshs);
    freshs
    
  let certicoq_eval opts env sigma c imports =
    let fresh_name = find_fresh opts.filename !all_run_functions in
    let opts = { opts with toplevel_name = fresh_name ^ "_body"; filename = fresh_name } in
    certicoq_eval_named opts env sigma fresh_name c imports

  let run_existing opts env sigma c id run =
    let tyinfo = 
      let ty = Retyping.get_type_of env sigma c in        
      check_reifyable env sigma ty
    in
    let result = 
      if opts.time then time ~msg:Pp.(str"Running " ++ id) run
      else run ()
    in
    debug_msg opts.debug (Printf.sprintf "Running the dynamic linked program succeeded, reifying result");
    reify env sigma tyinfo result
    
  let certicoq_eval opts env sigma c imports =
    match exists_certicoq_run opts.filename with
    | None -> certicoq_eval opts env sigma c imports
    | Some run -> 
      debug_msg opts.debug (Printf.sprintf "Retrieved earlier compiled code for %s" opts.filename);
      run_existing opts env sigma c (Pp.str opts.filename) run

  let compile_shared_C opts gr imports =
    let env = Global.env () in
    let sigma = Evd.from_env env in
    let sigma, c = Evd.fresh_global env sigma gr in
    let name = Names.Id.to_string (Nametab.basename_of_global gr) in
    match exists_certicoq_run name with
    | None ->
      let opts = { opts with toplevel_name = name ^ "_body"; } in
      certicoq_eval_named opts env sigma name c imports
    | Some run -> run_existing opts env sigma c (Pp.str name) run
    
  let print_to_file (s : string) (file : string) =
    let f = open_out file in
    Printf.fprintf f "%s\n" s;
    close_out f


  let show_ir opts gr =
    let term = quote opts gr in
    let debug = opts.debug in
    let options = make_pipeline_options opts in
    let p = Pipeline.show_IR options (Obj.magic term) in
    match p with
    | (CompM.Ret prg, dbg) ->
      debug_msg debug "Finished compiling, printing to file.";
      let time = Unix.gettimeofday() in
      let suff = opts.ext in
      let fname = opts.filename in
      let file = fname ^ suff ^ ".ir" in
      print_to_file (string_of_bytestring prg) file;
      let time = (Unix.gettimeofday() -. time) in
      debug_msg debug (Printf.sprintf "Printed to file %s in %f s.." file time);
      debug_msg debug "Pipeline debug:";
      debug_msg debug (string_of_bytestring dbg)
    | (CompM.Err s, dbg) ->
      debug_msg debug "Pipeline debug:";
      debug_msg debug (string_of_bytestring dbg);
      CErrors.user_err Pp.(str "Could not compile: " ++ (pr_string s) ++ str "\n")


  (* Quote Coq inductive type *)
  let quote_ind opts gr : Metacoq_template_plugin.Ast_quoter.quoted_program * string =
    let debug = opts.debug in
    let env = Global.env () in
    let sigma = Evd.from_env env in
    let sigma, c = Evd.fresh_global env sigma gr in
    let name = match gr with
      | Names.GlobRef.IndRef i -> 
          let (mut, _) = i in
          Names.KerName.to_string (Names.MutInd.canonical mut)
      | _ -> CErrors.user_err
        Pp.(Printer.pr_global gr ++ str " is not an inductive type") in
    debug_msg debug "Quoting";
    let time = Unix.gettimeofday() in
    let term = quote_term_rec ~bypass:true env sigma (EConstr.to_constr sigma c) in
    let time = (Unix.gettimeofday() -. time) in
    debug_msg debug (Printf.sprintf "Finished quoting in %f s.." time);
    (term, name)

  let ffi_command opts gr =
    let (term, name) = quote_ind opts gr in
    let debug = opts.debug in
    let options = make_pipeline_options opts in

    let time = Unix.gettimeofday() in
    (match CI.generate_ffi options (Obj.magic term) with
    | CompM.Ret (((nenv, header), prg), logs) ->
      let time = (Unix.gettimeofday() -. time) in
      debug_msg debug (Printf.sprintf "Generated FFI glue code in %f s.." time);
      (match logs with [] -> () | _ ->
        debug_msg debug (Printf.sprintf "Logs:\n%s" (String.concat "\n" (List.map string_of_bytestring logs))));
      let time = Unix.gettimeofday() in
      let suff = opts.ext in
      let cstr = ("ffi." ^ name ^ suff ^ ".c") in
      let hstr = ("ffi." ^ name ^ suff ^ ".h") in
      CI.printProg prg nenv cstr [];
      CI.printProg header nenv hstr [];

      let time = (Unix.gettimeofday() -. time) in
      debug_msg debug (Printf.sprintf "Printed FFI glue code to file in %f s.." time)
    | CompM.Err s ->
      CErrors.user_err Pp.(str "Could not generate FFI glue code: " ++ pr_string s))

  let glue_command opts grs =
    let terms = grs |> List.rev
                |> List.map (fun gr -> Metacoq_template_plugin.Ast0.Env.declarations (fst (quote opts gr))) 
                |> List.concat |> nub in
    generate_glue true opts (Obj.magic terms)

end

module MLCompile = CompileFunctor (MLCompiler)
include MLCompile

(*****************************************************************************

  Liquidsoap, a programmable stream generator.
  Copyright 2003-2024 Savonet team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details, fully stated in the COPYING
  file at the root of the liquidsoap distribution.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301  USA

 *****************************************************************************)

(** Show debugging information. *)
let debug = ref (Sys.getenv_opt "LIQUIDSOAP_DEBUG_LANG" <> None)

(** Show variables levels. *)
let debug_levels = ref false

let debug_variance = ref false

(* Type information comes attached to the AST from the parsing,
 * with appropriate sharing of the type variables. Then the type inference
 * performs in-place unification.
 *
 * In order to report precise type error messages, we put very dense
 * parsing location information in the type. Every layer of it can have
 * a location. Destructive unification introduces links in such a way
 * that the old location is still accessible.
 *
 * The level annotation represents the number of abstractions which surround
 * the type in the AST -- function arguments and let-in definitions.
 * It is used to safely generalize types.
 *
 * Finally, constraints can be attached to existential (unknown, '_a)
 * and universal ('a) type variables. *)

(** {2 Types} *)

type variance = [ `Covariant | `Invariant ]

(** Type description *)
type descr = ..

(** A type *)
type t = { pos : Pos.Option.t; descr : descr }

(** Constraint type *)
type constr_t = ..

type constr_t += Num | Ord | Record

type constr = {
  t : constr_t;
  constr_descr : string;
  univ_descr : string option;
  satisfied : subtype:(t -> t -> unit) -> satisfies:(t -> unit) -> t -> unit;
}

module Constraints = Set.Make (struct
  type t = constr

  let compare { t } { t = t' } = Stdlib.compare t t'
end)

(** A type constructor applied to arguments (e.g. source). *)
type constructed = { constructor : string; params : (variance * t) list }

(** Contents of a variable. *)
type var = {
  name : int;
  mutable level : int;
  mutable constraints : Constraints.t;
}

type invar =
  | Free of var  (** the variable is free *)
  | Link of variance * t  (** the variable has bee substituted *)

(** A type scheme (i.e. a type with universally quantified variables). *)
type scheme = var list * t

(** A method. *)
type meth = {
  meth : string;  (** name of the method *)
  optional : bool;  (** is the method optional? *)
  scheme : scheme;  (** type scheme *)
  doc : string;  (** documentation *)
  json_name : string option;  (** name when represented as JSON *)
}

type repr_t = { t : t; json_repr : [ `Tuple | `Object ] }

(** Sets of type descriptions. *)
module DS = Set.Make (struct
  type t = string * Constraints.t

  let compare (s, v) (s', v') =
    match Stdlib.compare s s' with 0 -> Constraints.compare v v' | x -> x
end)

let string_of_constr c = c.constr_descr

type 'a argument = bool * string * 'a

module R = struct
  type meth = {
    name : string;
    optional : bool;
    scheme : var list * t;
    json_name : string option;
  }

  and t =
    [ `Constr of string * (variance * t) list
    | `List of t * [ `Object | `Tuple ]
    | `Tuple of t list
    | `Nullable of t
    | `Meth of meth * t (* label, type scheme, JSON name, base type *)
    | `Arrow of t argument list * t
    | `Getter of t
    | `EVar of var (* existential variable *)
    | `UVar of var (* universal variable *)
    | `Ellipsis (* omitted sub-term *)
    | `Range_Ellipsis (* omitted sub-terms (in a list, e.g. list of args) *)
    | `Debug of
      string * t * string
      (* add annotations before / after, mostly used for debugging *) ]

  and var = string * Constraints.t
end

type custom = ..

type custom_handler = {
  typ : custom;
  copy_with : (t -> t) -> custom -> custom;
  occur_check : (t -> unit) -> custom -> unit;
  filter_vars : (var list -> t -> var list) -> var list -> custom -> var list;
  repr : (var list -> t -> R.t) -> var list -> custom -> R.t;
  subtype : (t -> t -> unit) -> custom -> custom -> unit;
  sup : (t -> t -> t) -> custom -> custom -> custom;
  to_string : custom -> string;
}

type descr +=
  | Custom of custom_handler
  | Constr of constructed
  | Getter of t  (** a getter: something that is either a t or () -> t *)
  | List of repr_t
  | Tuple of t list
  | Nullable of t  (** something that is either t or null *)
  | Meth of meth * t  (** t with a method added *)
  | Arrow of t argument list * t  (** a function *)
  | Var of invar ref  (** a type variable *)

exception NotImplemented
exception Exists of Pos.Option.t * string
exception Unsatisfied_constraint

let unit = Tuple []

(** Operations on variables. *)
module Var = struct
  type t = var

  (** Compare two variables for equality. This comparison should always be used
      to compare variables (as opposed to =). *)
  let eq v v' = v.name = v'.name

  let compare v v' = compare v.name v'.name
end

(** Sets of variables. *)
module Vars = struct
  include Set.Make (Var)

  let add_list l v = add_seq (List.to_seq l) v
end

(** Create a type from its value. *)
let make ?pos d = { pos; descr = d }

(** Dereferencing gives you the meaning of a term, going through links created
    by instantiations. One should (almost) never work on a non-dereferenced
    type. *)
let rec deref t =
  match t.descr with Var { contents = Link (_, t) } -> deref t | _ -> t

(** Remove methods. This function also removes links. *)
let rec demeth t =
  let t = deref t in
  match t.descr with Meth (_, t) -> demeth t | _ -> t

(* This should preserve pos *)
let rec deep_demeth t =
  let t' =
    match deref t with
      | { descr = Getter t' } as t -> { t with descr = Getter (deep_demeth t') }
      | { descr = List repr } as t ->
          { t with descr = List { repr with t = deep_demeth repr.t } }
      | { descr = Tuple l } as t ->
          { t with descr = Tuple (List.map deep_demeth l) }
      | { descr = Nullable t' } as t ->
          { t with descr = Nullable (deep_demeth t') }
      | { descr = Meth (_, t) } -> deep_demeth t
      | { descr = Arrow (l, t') } as t ->
          {
            t with
            descr =
              Arrow
                ( List.map (fun (x, y, t) -> (x, y, deep_demeth t)) l,
                  deep_demeth t' );
          }
      | t -> t
  in
  { t' with pos = t.pos }

let rec filter_meths t fn =
  let t = deref t in
  match t.descr with
    | Meth (m, t) when not (fn m) -> filter_meths t fn
    | Meth (m, t) -> { t with descr = Meth (m, filter_meths t fn) }
    | _ -> t

(** Put the methods of the first type around the second type. *)
let rec remeth t u =
  let t = deref t in
  match t.descr with
    | Meth (m, t) -> { t with descr = Meth (m, remeth t u) }
    | _ -> u

(** Type of a method in a type. *)
let rec invoke t l =
  match (deref t).descr with
    | Meth (m, _) when m.meth = l -> m.scheme
    | Meth (_, t) -> invoke t l
    | _ -> raise Not_found

(** Do we have a method with given label? *)
let has_meth t l =
  try
    ignore (invoke t l);
    true
  with Not_found -> false

(** Type of a submethod in a type. *)
let rec invokes t = function
  | l :: ll ->
      let g, t = invoke t l in
      if ll = [] then (g, t) else invokes t ll
  | [] -> ([], t)

(** Add a method to a type. *)
let meth ?pos ?json_name ?(optional = false) meth scheme ?(doc = "") t =
  make ?pos (Meth ({ meth; optional; scheme; doc; json_name }, t))

(** Add a submethod to a type. *)
let rec meths ?pos l v t =
  match l with
    | [] -> assert false
    | [l] -> meth ?pos l v t
    | l :: ll ->
        let g, tl = invoke t l in
        let v = meths ?pos ll v tl in
        meth ?pos l (g, v) t

(** Split the methods from the type. *)
let split_meths t =
  let rec aux hide t =
    let t = deref t in
    match t.descr with
      | Meth (m, t) ->
          let meth, t = aux (m.meth :: hide) t in
          let meth = if List.mem m.meth hide then meth else m :: meth in
          (meth, t)
      | _ -> ([], t)
  in
  aux [] t

(** Create a fresh variable. *)
let var_name =
  let c = ref (-1) in
  fun () ->
    incr c;
    !c

let var =
  let f ?(constraints = []) ?(level = max_int) ?pos () =
    let constraints = Constraints.of_list constraints in
    let name = var_name () in
    make ?pos (Var (ref (Free { name; level; constraints })))
  in
  f

module Fresh = struct
  type mapper = {
    level : int option;
    selector : var -> bool;
    var_maps : (var, var) Hashtbl.t;
    link_maps : (invar ref, invar ref) Hashtbl.t;
  }

  let init ?(selector = fun _ -> true) ?level () =
    {
      level;
      selector;
      var_maps = Hashtbl.create 10;
      link_maps = Hashtbl.create 10;
    }

  let make_var { level; selector; var_maps } var =
    if not (selector var) then var
    else (
      try Hashtbl.find var_maps var
      with Not_found ->
        let level = Option.value ~default:var.level level in
        let new_var = { var with name = var_name (); level } in
        Hashtbl.add var_maps var new_var;
        new_var)

  let make ({ selector; link_maps } as h) t =
    let map_var = make_var h in
    let map_descr map = function
      | Custom c -> Custom { c with typ = c.copy_with map c.typ }
      | Constr { constructor; params } ->
          Constr
            { constructor; params = List.map (fun (v, t) -> (v, map t)) params }
      | Getter t -> Getter (map t)
      | List { t; json_repr } -> List { t = map t; json_repr }
      | Tuple l -> Tuple (List.map map l)
      | Nullable t -> Nullable (map t)
      | Meth ({ meth; optional; scheme = vars, t; doc; json_name }, t') ->
          Meth
            ( {
                meth;
                optional;
                scheme = (List.map map_var vars, map t);
                doc;
                json_name;
              },
              map t' )
      | Arrow (args, t) ->
          Arrow (List.map (fun (b, s, t) -> (b, s, map t)) args, map t)
      (* Here we keep all links. While it could be tempting to deref,
         we are using links to compute type supremum in type unification
         so we are better off keeping them. Also, we need to create fresh
         links to make sure that a suppremum computation in the refreshed
         type does not impact the original type. *)
      | Var ({ contents = Link (v, t) } as link) ->
          Var
            (try Hashtbl.find link_maps link
             with Not_found ->
               let new_link = { contents = Link (v, map t) } in
               Hashtbl.add link_maps link new_link;
               new_link)
      | Var ({ contents = Free var } as link) as descr ->
          if not (selector var) then descr
          else
            Var
              (try Hashtbl.find link_maps link
               with Not_found ->
                 let new_link = { contents = Free (map_var var) } in
                 Hashtbl.add link_maps link new_link;
                 new_link)
      | _ -> assert false
    in
    let rec map { descr } = { pos = None; descr = map_descr map descr } in
    map t
end

let fresh t = Fresh.make (Fresh.init ()) t

let to_string_fun =
  ref (fun ?(generalized : var list option) _ ->
      ignore generalized;
      failwith "Type.to_string not defined yet")

(** String representation of a type. *)
let to_string ?generalized (t : t) : string = !to_string_fun ?generalized t

let string_of_scheme (g, t) = to_string ~generalized:g t
let is_fun t = match (demeth t).descr with Arrow _ -> true | _ -> false

let is_source t =
  match (demeth t).descr with
    | Constr { constructor = "source"; _ } -> true
    | _ -> false

let custom_types : (string, unit -> t) Hashtbl.t = Hashtbl.create 10

let register_type name custom =
  let mk_typ =
    match Hashtbl.find_opt custom_types name with
      | Some mk_typ -> fun () -> remeth (mk_typ ()) (custom ())
      | None -> custom
  in
  Hashtbl.replace custom_types name mk_typ

let register_type name custom =
  match String.split_on_char '.' name with
    | [] -> assert false
    | name :: [] -> register_type name custom
    | root :: names ->
        let default_mk_typ () = make unit in
        let root_mk_typ =
          Option.value ~default:default_mk_typ
            (Hashtbl.find_opt custom_types root)
        in
        let rec f root_typ = function
          | [] -> assert false
          | name :: [] -> meth name ([], custom ()) root_typ
          | name :: names ->
              let typ =
                try snd (invoke root_typ name) with _ -> default_mk_typ ()
              in
              meth name ([], f typ names) root_typ
        in
        Hashtbl.replace custom_types root (fun () -> f (root_mk_typ ()) names)

let find_type_opt = Hashtbl.find_opt custom_types

let rec mk_invariant t =
  match t with
    | { descr = Var ({ contents = Link (_, t) } as c) } ->
        c := Link (`Invariant, t);
        mk_invariant t
    | _ -> ()

let type_of_encoder =
  ref (fun ~pos:_ _ -> failwith "Encoders are not implemented!")

type encoder_params =
  (string * [ `Value of Value.t | `Encoder of encoder ]) list

and encoder = string * encoder_params

let make_encoder =
  ref (fun ~pos:_ _ _ -> failwith "Encoders are not implemented!")

let has_encoder = ref (fun _ -> false)
let liq_libs_dir = ref (fun () -> raise Not_found)
let log_path = ref None
let source_eval_check = ref (fun ~k:_ ~pos:_ _ -> ())
let collect_after = ref (fun fn -> fn ())

module type Regexp_t = Regexp.T

let regexp = Regexp.regexp_ref

type log =
  < f : 'a. int -> ('a, unit, string, unit) format4 -> 'a
  ; critical : 'a. ('a, unit, string, unit) format4 -> 'a
  ; severe : 'a. ('a, unit, string, unit) format4 -> 'a
  ; important : 'a. ('a, unit, string, unit) format4 -> 'a
  ; info : 'a. ('a, unit, string, unit) format4 -> 'a
  ; debug : 'a. ('a, unit, string, unit) format4 -> 'a >

let make_log =
  ref (fun name ->
      let name = String.concat "." name in
      object (self : log)
        method f lvl =
          let time = Unix.gettimeofday () in
          Printf.ksprintf (fun s ->
              List.iter
                (Printf.printf "%f [%s:%d]: %s" time name lvl)
                (String.split_on_char '\n' s))

        method critical = self#f 1
        method severe = self#f 2
        method important = self#f 3
        method info = self#f 4
        method debug = self#f 5
      end)

let log name =
  object (self : log)
    method f lvl = (!make_log name)#f lvl
    method critical = self#f 1
    method severe = self#f 2
    method important = self#f 3
    method info = self#f 4
    method debug = self#f 5
  end

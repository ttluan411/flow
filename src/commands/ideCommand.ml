(**
 * Copyright (c) 2013-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(***********************************************************************)
(* flow ide command *)
(***********************************************************************)

open CommandUtils

module Prot = Persistent_connection_prot

let protocol_options = ["very-unstable"; "human-readable"]

let protocol_options_string = String.concat ", " protocol_options

let spec = {
  CommandSpec.
  name = "ide";
  doc =
    "Starts a persistent connection to the server. Currently in development and highly unstable";
  usage = Printf.sprintf
    "Usage: %s ide\n\n\
      Starts a persistent connection to the server\n"
      CommandUtils.exe_name;
  args = CommandSpec.ArgSpec.(
    empty
    |> server_flags
    |> root_flag
    |> from_flag
    |> flag "--protocol" (required (enum protocol_options))
        ~doc:("Indicates the protocol to be used. One of: " ^ protocol_options_string)
    |> strip_root_flag
    (* TODO use this somehow? |> verbose_flags *)
  )
}

module type ClientProtocol = sig
  val server_request_of_stdin_message: Buffered_line_reader.t -> Prot.request option
  val handle_server_response: strip_root:Path.t option -> Prot.response -> unit
end

module HumanReadable: ClientProtocol = struct
  let server_request_of_stdin_message buffered_stdin =
    let line = Buffered_line_reader.get_next_line buffered_stdin in
    let tokens = Str.split (Str.regexp "[ \t\r\n]+") line in
    match tokens with
      | ["subscribe"] -> Some Prot.Subscribe
      (* For human-readable mode (which is just for playing around, basically)
       * you need to include the file contents on the same line, and it must
       * also have the magic token. *)
      | "autocomplete"::file::contents ->
          let fileinput = File_input.FileContent (Some file, String.concat " " contents) in
          Some (Prot.Autocomplete (fileinput, 0 (* use a dummy id *)))
      (* Ensure files is not empty *)
      | "open"::f::fs ->
        Some (Prot.DidOpen (f, fs))
      | "close"::f::fs ->
        Some (Prot.DidClose (f, fs))
      | _ ->
        prerr_endline ("Command not recognized: " ^ line); None

  let handle_autocomplete = function
    | Error _ -> print_endline "Autocomplete Error"
    | Ok completions ->
        print_endline "Autocomplete results:";
        completions |>
        List.map (fun r -> r.AutocompleteService_js.res_name) |>
        List.iter (Printf.printf "  %s\n");
        flush stdout


  let handle_server_response ~strip_root:_ = function
    | Prot.Errors {errors; warnings} ->
      let err_count = Errors.ErrorSet.cardinal errors in
      let warn_count = Errors.ErrorSet.cardinal warnings in
      print_endline ("Received " ^ (string_of_int err_count) ^ " errors and "
        ^ (string_of_int warn_count) ^ " warnings")
    | Prot.StartRecheck -> print_endline "Start recheck"
    | Prot.EndRecheck -> print_endline "End recheck"
    | Prot.AutocompleteResult (result, _ (* ignore id *)) -> handle_autocomplete result
    | Prot.DidOpenAck -> print_endline "Received file open ack"
    | Prot.DidCloseAck -> print_endline "Received file close ack"

end

module VeryUnstable: ClientProtocol = struct
  let print_errors ~strip_root errors warnings =
    (* Because the file-tracking portion of the protocol already handles which warnings
     * we display, we don't want the printer removing them. *)
    let json_errors = Errors.Json_output.full_status_json_of_errors
      ~strip_root ~suppressed_errors:([]) ~errors ~warnings () in
    let json_message = Json_rpc.jsonrpcize_notification "diagnosticsNotification" [json_errors] in
    let json_string = Hh_json.json_to_string json_message in
    Http_lite.write_message stdout json_string;
    prerr_endline "sent diagnostics notification"

  let print_message message () =
    []
      |> Json_rpc.jsonrpcize_notification message
      |> Hh_json.json_to_string
      |> Http_lite.write_message stdout

  let print_start_recheck = print_message "startRecheck"

  let print_end_recheck = print_message "endRecheck"

  let print_autocomplete ~strip_root response id =
    AutocompleteService_js.autocomplete_response_to_json ~strip_root response
      |> Json_rpc.jsonrpcize_response id
      |> Hh_json.json_to_string
      |> Http_lite.write_message stdout

  let handle_server_response ~strip_root = function
    | Prot.Errors {errors; warnings} ->
      print_errors ~strip_root errors warnings
    | Prot.StartRecheck -> print_start_recheck ()
    | Prot.EndRecheck -> print_end_recheck ()
    | Prot.AutocompleteResult (result, id) -> print_autocomplete ~strip_root result id
    (* No need to send the client anything; these acks are to prevent deadlocks
     * involving the buffers between the ide command and the flow server *)
    | Prot.DidOpenAck -> ()
    | Prot.DidCloseAck -> ()

  let handle_autocomplete id = Hh_json.(function
    | [JSON_String file; JSON_Number line_str; JSON_Number column_str; JSON_String contents] ->
        let file = get_path_of_file file in
        let line = int_of_string line_str in
        let column = int_of_string column_str in
        let (line, column) = convert_input_pos (line, column) in
        let with_token = AutocompleteService_js.add_autocomplete_token contents line column in
        Some (Prot.Autocomplete (File_input.FileContent (Some file, with_token), id))
    | _ ->
        prerr_endline
          "Incorrect arguments passed to autocomplete. Should be filepath, line, column, contents";
        None
  )

  (* Converts a list of json strings into a non-empty string list.
   * Returns Some files on success; None otherwise. *)
  let unjsonify_files =
    let unjsonify_file files = Hh_json.(function
      | JSON_String file ->
        let file = get_path_of_file file in
        Option.bind files (fun files -> Some (file::files))
      (* Fail on a non-string argument. *)
      | _ -> None
    ) in
    fun files ->
      match List.fold_left unjsonify_file (Some []) files with
        | None -> None
        (* Fail on an empty argument list. *)
        | Some [] -> None
        | Some (f::fs) -> Some (f, fs)

  let handle_did_open files =
    match unjsonify_files files with
      | Some processed_files -> Some (Prot.DidOpen processed_files)
      | None ->
        prerr_endline "Incorrect arguments passed to didOpen. Should be filepath, ...filepaths";
        None

  let handle_did_close files =
    match unjsonify_files files with
      | Some processed_files -> Some (Prot.DidClose processed_files)
      | None ->
        prerr_endline "Incorrect arguments passed to didClose. Should be filepath, ...filepaths";
        None

  let server_request_of_stdin_message buffered_stdin =
    let message = try
      Some (Http_lite.read_message_utf8 buffered_stdin)
    with Http_lite.Malformed _ ->
      prerr_endline "Received a malformed http message";
      None
    in
    match message with
      | None -> None
      | Some message ->
          let obj = Json_rpc.parse_json_rpc_response message in
          match obj with
            | Json_rpc.Obj ("subscribeToDiagnostics", _, None) ->
                prerr_endline "received subscribe request";
                Some Prot.Subscribe
            | Json_rpc.Obj ("autocomplete", params, Some id) ->
                handle_autocomplete id params
            | Json_rpc.Obj ("didOpen", params, None) ->
              handle_did_open params
            | Json_rpc.Obj ("didClose", params, None) ->
              handle_did_close params
            | Json_rpc.Obj (method_name, _, id) ->
                let id_str = match id with None -> "no id" | Some _ -> "an id" in
                prerr_endline
                  ("unrecognized method: " ^ method_name ^ " with " ^ id_str ^ " provided");
                None
            | Json_rpc.Malformed err ->
                prerr_endline ("Received a malformed message: " ^ err);
                None
end

module PendingRequests : sig
  type t
  val empty: t
  val add_request: t -> Prot.request -> t
  val add_response: t -> Prot.response -> t
  val ready_request: t -> (Prot.request option * t)
end = struct
  type t = {
    queue: Prot.request ImmQueue.t;
    outstanding: Prot.request option;
  }

  let empty = {
    queue = ImmQueue.empty;
    outstanding = None;
  }

  let add_request t req =
    { t with
      queue = ImmQueue.push t.queue req;
    }

  let add_response t response =
    let open Prot in
    match response, t.outstanding with
      | Errors _, _
      | StartRecheck, _
      | EndRecheck, _ ->
          t
      | AutocompleteResult (_, response_id), Some (Autocomplete (_, request_id)) ->
          if response_id <> request_id then begin
            failwith "Internal error: request and response id mismatch."
          end;
          { t with outstanding = None }
      | DidOpenAck, Some (DidOpen _) ->
          { t with outstanding = None }
      | DidCloseAck, Some (DidClose _) ->
          { t with outstanding = None }
      (* Explicit matches on response instead of `_` to make adding to the protocol easier. *)
      | (AutocompleteResult _ | DidOpenAck | DidCloseAck), Some _ ->
          failwith "Internal error: received a mismatched response type"
      | (AutocompleteResult _ | DidOpenAck | DidCloseAck), None ->
          failwith "Internal error: received a response when there was no outstanding request."

  let ready_request t =
    match t.outstanding with
      | Some _ -> (None, t)
      | None -> begin
          match ImmQueue.pop t.queue with
            | None, q -> (None, { t with queue = q })
            | Some req, q ->
                let outstanding = match req with
                  (* We do not expect a response from `subscribe` *)
                  | Prot.Subscribe -> None
                  | Prot.Autocomplete _ | Prot.DidOpen _ | Prot.DidClose _ -> Some req
                in
                (Some req, { outstanding; queue = q })
        end
end

module ProtocolFunctor (Protocol: ClientProtocol) = struct
  (* not to be confused with genv or env -- this is state local to the IDE
   * command process *)
  type local_env = {
    pending_requests: PendingRequests.t;
    is_server_ready: bool;
  }

  let handle_server_response ~strip_root fd local_env =
    if not (local_env.is_server_ready) then
      (* The server reads the first message (CONNECT, which establishes this
       * connection as a persistent connection rather than a short-lived one)
       * using the built-in Marshal module. This is based on OCaml channels,
       * which have a buffer. If we send any subsequent messages before the
       * server has read the first message, then it is possible for that message
       * to be stored in the OCaml channel's buffer. Then, when we `select` on
       * the underlying fd, it never comes up as readable, since the message we
       * expect to receive has already been read into the buffer.
       *
       * We use Marshal_tools to write/read directly from the underlying fd in
       * order to avoid this problem. However, we need to make sure that we
       * don't start writing until after the server reads from the OCaml
       * channel. So, after it does so, it sends down a single `unit` message
       * down, indicating that it is now ready to start receiving messages.
       *
       * This handshake would not be necessary if we converted all client/server
       * communication to use Marshal_tools rather than the built-in Marshal
       * module. *)
      let () = Marshal_tools.from_fd_with_preamble fd in
      { local_env with is_server_ready = true }
    else
      let (message : Prot.response) =
        try
          Marshal_tools.from_fd_with_preamble fd
        with
        | Unix.Unix_error (Unix.ECONNRESET, _, _) ->
          (* Windows throws ECONNRESET when the connection dies *)
          let msg = "Server closed the connection via an ECONNRESET" in
          FlowExitStatus.(exit ~msg No_server_running)
        | End_of_file ->
          let msg = "Server closed the connection via an End_of_file" in
          FlowExitStatus.(exit ~msg No_server_running)
      in
      let pending_requests =
        PendingRequests.add_response local_env.pending_requests message
      in
      Protocol.handle_server_response ~strip_root message;
      { local_env with pending_requests }

  let send_server_request fd msg =
    Marshal_tools.to_fd_with_preamble fd (msg: Prot.request)

  let handle_stdin_message buffered_stdin local_env =
    match Protocol.server_request_of_stdin_message buffered_stdin with
      | None -> local_env
      | Some req ->
          let pending_requests =
            PendingRequests.add_request local_env.pending_requests req
          in
          { local_env with pending_requests }

  let rec handle_all_stdin_messages buffered_stdin local_env =
    let local_env = handle_stdin_message buffered_stdin local_env in
    if Buffered_line_reader.has_buffered_content buffered_stdin then
      handle_all_stdin_messages buffered_stdin local_env
    else
      local_env

  let rec send_pending_requests fd local_env =
    if not (local_env.is_server_ready) then
      local_env
    else
      let (req, pending_requests) =
        PendingRequests.ready_request local_env.pending_requests
      in
      let local_env = { local_env with pending_requests } in
      match req with
        | None -> local_env
        | Some req -> begin
            send_server_request fd req;
            send_pending_requests fd local_env
          end

  let main_loop ~buffered_stdin ~ic_fd ~oc_fd ~strip_root =
    let stdin_fd = Buffered_line_reader.get_fd buffered_stdin in
    let local_env =
      ref {
        pending_requests = PendingRequests.empty;
        is_server_ready = false;
      }
    in
    while true do
      local_env := send_pending_requests oc_fd !local_env;
      (* Negative timeout means this call will wait indefinitely *)
      let readable_fds, _, _ = Unix.select [stdin_fd; ic_fd] [] [] ~-.1.0 in
      List.iter (fun fd ->
        if fd = ic_fd then begin
          local_env := handle_server_response ~strip_root ic_fd !local_env
        end else if fd = stdin_fd then begin
          local_env := handle_all_stdin_messages buffered_stdin !local_env
        end else
          failwith "Internal error: select returned an unknown fd"
      ) readable_fds
    done
end

module VeryUnstableProtocol = ProtocolFunctor(VeryUnstable)
module HumanReadableProtocol = ProtocolFunctor(HumanReadable)

let main option_values root from protocol strip_root () =
  FlowEventLogger.set_from from;
  let root = CommandUtils.guess_root root in
  let strip_root = if strip_root then Some root else None in
  let ic, oc = connect option_values root in
  send_command oc ServerProt.CONNECT;
  let buffered_stdin = stdin |> Unix.descr_of_in_channel |> Buffered_line_reader.create in
  let ic_fd = Timeout.descr_of_in_channel ic in
  let oc_fd = Unix.descr_of_out_channel oc in
  let main_loop = match protocol with
    | "very-unstable" -> VeryUnstableProtocol.main_loop
    | "human-readable" -> HumanReadableProtocol.main_loop
    | x -> failwith ("Internal error: unknown protocol '" ^ x ^ "'")
  in
  main_loop ~buffered_stdin ~ic_fd ~oc_fd ~strip_root

let command = CommandSpec.command spec main

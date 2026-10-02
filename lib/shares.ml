let wkro_tag sub =
  "wkro-" ^ String.sub (Digest.to_hex (Digest.string sub)) 0 12

let in_tag i = Printf.sprintf "in-%d" i

(* policy.shares entries land at tag share-<index>, matching what
   _guest.nix emits. Independent of in-<i> for inputs because the two
   come from different policy fields and the indices would clash. *)
let share_tag i = Printf.sprintf "share-%d" i

(* Config binds are tagged per agent (auth-<name>) — _guest.nix emits the
   same names. A single-agent VM therefore has auth-claude, not auth. *)
let auth_tag (a : Policy.agent) = "auth-" ^ a.name

let ro_tags (p : Policy.t) =
  let acc = ref [ "vmcfg" ] in
  (match p.auth with
   | Bind ->
       List.iter (fun a -> acc := auth_tag a :: !acc) (Policy.agents p)
   | Ephemeral -> ());
  (match p.work.default with Ro -> acc := "work" :: !acc | Rw -> ());
  List.iter (fun sub -> acc := wkro_tag sub :: !acc) p.work.read_only;
  List.iteri (fun i _ -> acc := in_tag i :: !acc) p.inputs;
  List.iteri
    (fun i (s : Policy.share) ->
      if s.read_only then acc := share_tag i :: !acc)
    p.shares;
  List.rev !acc

type manifest_entry = {
  tag : string;
  source : string;
  socket : string;
}

let read_manifest ~runner =
  let dir = runner ^ "/share/microvm/virtiofs" in
  if not (Sys.file_exists dir) then []
  else
    Sys.readdir dir
    |> Array.to_list
    |> List.sort compare
    |> List.filter_map (fun tag ->
         let tag_dir = dir ^ "/" ^ tag in
         if Sys.is_directory tag_dir then
           Some
             {
               tag;
               source = Util.read_file_trimmed (tag_dir ^ "/source");
               socket = Util.read_file_trimmed (tag_dir ^ "/socket");
             }
         else None)

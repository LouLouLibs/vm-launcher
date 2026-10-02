let egress_hosts (p : Policy.t) =
  String.concat "\n" p.egress.hosts ^ "\n"

(* Rendered per agent: a two-agent VM gets a CLAUDE.md and an AGENTS.md,
   each written from the point of view of the agent that will read it. *)
let instructions ~(agent : Policy.agent) (p : Policy.t) =
  let basename = Filename.basename p.project in
  let egress_list = String.concat ", " p.egress.hosts in
  let julia_env = p.julia.env in
  let julia =
    List.exists (fun t -> t = "julia" || t = "julia-bin") p.tools
  in
  let gh_token =
    List.exists (fun (s : Policy.secret) -> s.env = "GH_TOKEN") p.secrets
  in
  let command = agent.command in
  let config_dir = agent.config_dir in
  let run_wrapper = agent.name ^ "-run" in
  let others =
    List.filter (fun (a : Policy.agent) -> a.name <> agent.name)
      (Policy.agents p)
  in
  let buf = Buffer.create 4096 in
  Buffer.add_string buf
    (Printf.sprintf "# vm-launcher session (%s)\n\n" basename);
  Buffer.add_string buf
    {|You are running inside a NixOS microVM (vm-launcher). Some context that
applies to this session specifically:

## Tools and conventions

|};
  (* Only claim what this policy actually provides. A GitHub token is
     there only if a secret exports it; julia wiring only if julia is in
     the toolset. Anything site-specific beyond that (a sysimage, a
     workflow convention) belongs in the policy's own [instructions]. *)
  if gh_token then
    Buffer.add_string buf
      "- **Use `gh`, not `curl`, for GitHub** — `GH_TOKEN` is preset for this\n  \
       project. `gh api`, `gh issue list`, `gh pr ...` all use it.\n";
  if julia then
    Buffer.add_string buf
      (Printf.sprintf
         "- **`JULIA_PROJECT=/work/%s` is set globally** — you don't need\n  \
          `--project` flags.\n"
         julia_env);
  Buffer.add_string buf
    (Printf.sprintf
       "- **`%s` is the prompts-off wrapper** if you ever shell out\n  \
        to %s from %s.\n"
       run_wrapper command command);
  (* Tell each agent who else is aboard. Two agents editing /work at the
     same time is the user's call, but neither should be surprised by
     changes it did not make. *)
  (match others with
   | [] -> ()
   | _ ->
       Buffer.add_string buf
         (Printf.sprintf
            "- **You are not alone in this VM.** Also installed: %s. A human \n  \
             may be running one right now in another window, so files under\n  \
             `/work` can change under you — re-read before you rewrite.\n"
            (String.concat ", "
               (List.map
                  (fun (a : Policy.agent) ->
                    Printf.sprintf "`%s` (start it with `%s-run`)" a.command a.name)
                  others))));
  Buffer.add_string buf
    "\n## Network egress\n\nOnly these hosts are reachable (everything else \
     fails at the in-VM proxy):\n\n";
  Buffer.add_string buf (Printf.sprintf "    %s\n\n" egress_list);
  Buffer.add_string buf
    {|If a fetch fails with "Connection refused" or "Could not resolve", the
likely cause is the proxy denying the host. Don't try to bypass the proxy.
The proxy log is at `/var/log/tinyproxy.log`.

## Persistence

- `/work` is the project (rw); subpaths under `work.readOnly` are RO
  — run `mount | grep /work` to see which.
|};
  if julia then
    Buffer.add_string buf
      "- `/work/.julia` is the Julia depot (persists across VM restarts).\n";
  Buffer.add_string buf
    (Printf.sprintf
       "- `~/%s/projects/` is the session log (persists; `%s --resume`\n  \
        works across VM restarts).\n"
       config_dir command);
  Buffer.add_string buf
    {|- The tmpfs root is wiped on shutdown; only the bridged dirs persist.

## What NOT to do

- **`/etc/vm-launcher/microvm-loaded.json` is the resolved policy this VM
  was built from** (egress mode, tools, shares, …) — it reflects any CLI
  overrides like `--egress`. (`microvm-loaded.ncl`, when present, is the
  verbatim source you passed and does NOT show overrides.) Both are
  mounted RO; policy changes happen on the host (typically via
  `vm-launcher --policy PATH`), not in here.
- **The system toolset is fixed at boot from `policy.tools`.** You can't
  add system-wide packages mid-session — `nix` isn't even in PATH, and
  the guest's /nix/store is a hermetic erofs image, not the host's.
  For project-local Python deps use `uv` in a venv.
|};
  if julia then
    Buffer.add_string buf
      "  For Julia, use `Pkg.add` (the depot at `/work/.julia` persists\n  \
       across restarts).\n";
  (match agent.instructions with
   | Some text when String.length text > 0 ->
       Buffer.add_string buf "\n---\n\n## Project-specific guidance\n\n";
       Buffer.add_string buf text;
       if String.length text > 0
          && text.[String.length text - 1] <> '\n'
       then Buffer.add_char buf '\n'
   | _ -> ());
  Buffer.contents buf

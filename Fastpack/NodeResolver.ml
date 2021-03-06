module StringSet = Set.Make(String)
module M = Map.Make(String)
module FS = FastpackUtil.FS

let debug = Logs.debug

type t = {
  resolve : Package.t -> string -> string -> (Module.location * string list) Lwt.t;
  find_package : string -> string -> Package.t Lwt.t;
}

exception Error of string

let empty =
  StringSet.empty
  |> StringSet.add "__empty_module__"
  |> StringSet.add "os"
  |> StringSet.add "module"
  |> StringSet.add "path"
  |> StringSet.add "fs"
  |> StringSet.add "domain"
  |> StringSet.add "console"
  |> StringSet.add "dns"
  |> StringSet.add "dgram"
  |> StringSet.add "timers"
  |> StringSet.add "crypto"
  |> StringSet.add "net"
  |> StringSet.add "events"
  |> StringSet.add "assert"
  |> StringSet.add "stream"
  |> StringSet.add "constants"
  |> StringSet.add "readable-stream"
  |> StringSet.add "assert"
  |> StringSet.add "buffer"
  |> StringSet.add "child_process"
  |> StringSet.add "cluster"
  |> StringSet.add "console"
  |> StringSet.add "constants"
  |> StringSet.add "crypto"
  |> StringSet.add "dgram"
  |> StringSet.add "dns"
  |> StringSet.add "domain"
  |> StringSet.add "events"
  |> StringSet.add "fs"
  |> StringSet.add "http"
  |> StringSet.add "https"
  |> StringSet.add "module"
  |> StringSet.add "net"
  |> StringSet.add "os"
  |> StringSet.add "path"
  |> StringSet.add "process"
  |> StringSet.add "punycode"
  |> StringSet.add "querystring"
  |> StringSet.add "readline"
  |> StringSet.add "repl"
  |> StringSet.add "stream"
  |> StringSet.add "string_decoder"
  |> StringSet.add "sys"
  |> StringSet.add "timers"
  |> StringSet.add "tls"
  |> StringSet.add "url"
  |> StringSet.add "util"
  |> StringSet.add "vm"
  |> StringSet.add "zlib"

let is_empty module_request =
  StringSet.mem module_request empty

let resolve_browser (package : Package.t) (path : string) =
  match package with
  | { filename = None; _ } ->
      None
  | { filename = Some filename; browser_shim; _ } ->
    let path = Package.normalize ~package_json_filename:(FilePath.dirname filename) path in
    match M.get path browser_shim with
    | None ->
      None
    | Some (Shim newPath) ->
      Some (Module.File { filename = Some newPath; preprocessors = [] })
    | Some Ignore ->
      Some Module.EmptyModule

let make
    ~(project_dir : string)
    ~(node_modules_paths : string list)
    ~(cache : Cache.t)
    ~(preprocessor : Preprocessor.t) =

  (** Try to resolve an absolute path *)
  let resolved_path = ref M.empty in
  let resolve_path path =
    match M.get path !resolved_path with
    | Some path ->
      Lwt.return path
    | None ->
      match%lwt cache.file_stat_opt path with
      | None -> Lwt.return_none
      | Some (stat, _) ->
        let%lwt resolved =
          match stat.st_kind with

          | Lwt_unix.S_DIR ->
            (* Check if directory contains package.json and read entry point from
               there if any *)
            let package_json_path = FilePath.concat path "package.json" in
            if%lwt cache.file_exists package_json_path then
              let%lwt { Package. entry_point; _ }, _ =
                cache.get_package package_json_path
              in
              Lwt.return_some (FS.abs_path path entry_point)
            else
              (** Check if directory contains index.js and return it if found *)
              let index_js_path = FilePath.concat path "index.js" in
              if%lwt cache.file_exists index_js_path then
                Lwt.return_some index_js_path
              else
                Lwt.return_none

          | Lwt_unix.S_REG ->
            Lwt.return_some path

          (* TODO: handle symlink *)
          | _ ->
            Lwt.return_none
        in
        resolved_path := M.add path resolved !resolved_path;
        Lwt.return resolved
  in

  (** Try to resolve an absolute path with different extensions *)
  let resolve_extensionless_path path =
    match%lwt resolve_path (path ^ ".js") with
    | Some _ as res -> Lwt.return res
    | None ->
      match%lwt resolve_path (path ^ ".jsx") with
      | Some _ as res -> Lwt.return res
      | None ->
        match%lwt resolve_path path with
        | Some _ as res -> Lwt.return res
        | None -> resolve_path (path ^ ".json")
  in

  let get_package_dependency {Package. filename; _} =
    match filename with
    | Some filename -> [filename]
    | None -> []
  in

  let resolve_package package_name path basedir =
    let try_paths =
      node_modules_paths
      |> List.map
        (fun node_modules_path ->
           match String.get node_modules_path 0 with
           | '/' -> [FilePath.concat node_modules_path package_name]
           | _ ->
             let rec gen_paths current_dir =
               let package_path =
                 FilePath.concat
                   (FilePath.concat current_dir node_modules_path)
                   package_name
               in
               if current_dir = project_dir
               then [package_path]
               else package_path :: (FilePath.dirname current_dir |> gen_paths)
             in
             gen_paths basedir
        )
      |> List.concat
    in
    Lwt_list.fold_left_s
      (fun resolved package_path ->
         match resolved with
         | Some _ -> Lwt.return resolved
         | None ->
           if%lwt cache.file_exists package_path then
            let package_json_path = FilePath.concat package_path "package.json" in
            let%lwt package =
              match%lwt cache.file_exists package_json_path with
              | false ->
                Lwt.return Package.empty
              | true ->
                let%lwt package, _ = cache.get_package package_json_path in
                Lwt.return package
            in
            let dep = get_package_dependency package in
            match path with
            | None ->
              let%lwt resolved = resolve_extensionless_path package_path in
              begin
                match resolved with
                | None ->
                  Lwt.return_none
                | Some resolved ->
                  Lwt.return_some (Module.resolved_file resolved, dep)
              end
            | Some path ->
              let path = FS.abs_path package_path path in
              match resolve_browser package path with
              | Some resolved ->
                Lwt.return_some (resolved, dep)
              | None ->
                let%lwt resolved = resolve_extensionless_path path in
                match resolved with
                | None ->
                  Lwt.return_none
                | Some resolved ->
                  Lwt.return_some (Module.resolved_file resolved, dep)
           else
             Lwt.return_none
      )
      None
      try_paths
  in

  let resolve_file (package : Package.t) path basedir =
    match path with

    | "" ->
      Lwt.fail (Error "Empty path")

    | path ->
      match String.get path 0 with

      (* relative module path *)
      | '.' ->
        (* TODO: make extensions be command-line parameter *)
        let try_extensions = [".js"; ".json"; ""] in
        let path = FS.abs_path basedir path in
        let resolved =
          List.fold_left
            (fun resolved ext ->
              match resolved with
              | Some _ -> resolved
              | None -> resolve_browser package (path ^ ext)
            )
            None
            try_extensions
        in
        begin
          match resolved with
          | Some resolved ->
            Lwt.return (resolved, get_package_dependency package)
          | None ->
            begin
              match%lwt resolve_extensionless_path path with
              | None ->
                Lwt.fail (Error path)
              | Some resolved ->
                Lwt.return (Module.resolved_file resolved,
                            get_package_dependency package)
            end
        end

      (* absolute module path *)
      (* should we be considering "browser" here *)
      | '/' ->
        begin
          match%lwt resolve_extensionless_path path with
          | None ->
            Lwt.fail (Error path)
          | Some resolved ->
            Lwt.return (Module.resolved_file resolved, [])
        end

      (* scoped package *)
      | '@' ->
        begin
          match resolve_browser package path with
          | Some resolved ->
            Lwt.return (resolved, get_package_dependency package)
          | None ->
            let package_name, path_in_package =
              match String.split_on_char '/' path with
              | [] ->
                (None, None)
              | _scope::[] ->
                (None, None)
              | scope::package::[] ->
                (Some (scope ^ "/" ^ package), None)
              | scope::package::rest ->
                (Some (scope ^ "/" ^ package), Some (String.concat "/" rest))
            in
            begin
              match package_name with
              | None ->
                Lwt.fail (Error path)
              | Some package_name ->
                match%lwt resolve_package package_name path_in_package basedir with
                | None ->
                  Lwt.fail (Error path)
                | Some resolved ->
                  Lwt.return resolved
            end
        end

      (* package *)
      | _ ->
        if is_empty path
        then
          Lwt.return (Module.EmptyModule, [])
        else
          if path = "$fp$runtime"
          then
            Lwt.return (Module.Runtime, [])
          else
            match resolve_browser package path with
            | Some resolved ->
              Lwt.return (resolved, get_package_dependency package)
            | None ->
              let package_name, path_in_package =
                match String.split_on_char '/' path with
                | [] -> (None, None)
                | package::[] -> (Some package, None)
                | package::rest -> (Some package, Some (String.concat "/" rest))
              in
              match package_name with
              | None ->
                Lwt.fail (Error path)
              | Some package_name ->
                match%lwt resolve_package package_name path_in_package basedir with
                | None ->
                  Lwt.fail (Error path)
                | Some resolved ->
                  Lwt.return resolved

  in

  let resolve (package : Package.t) request basedir =
    let resolve_preprocessors preprocessors =
      Lwt_list.fold_left_s
        (fun (preprocessors, all_deps) p ->
           let%lwt p, opts =
             match String.split_on_char '?' p with
             | [p] ->
               Lwt.return (p, "")
             | [p; opts] ->
               Lwt.return (p, opts)
             | _ ->
               (* TODO: better error reporting *)
               Lwt.fail (Error "bad preprrocessor format")
           in
           match p with
           | "builtin" ->
             Lwt.return (("builtin", "") :: preprocessors, all_deps)
           | _ ->
             let%lwt resolved = resolve_file package p basedir in
             match resolved with
             | Module.Main _, _
             | Module.EmptyModule, _
             | Module.Runtime, _
             | Module.File { filename = None; _ }, _ ->
               (* TODO: better error handling *)
               Lwt.fail (Error "Something weird when resolving preprocessors")
             | Module.File { filename = Some filename; _}, deps ->
               Lwt.return ((filename, opts) :: preprocessors,
                           deps @ all_deps)
        )
        ([], [])
        preprocessors
    in
    let rec resolve_parts ?(preprocess=true) parts =
      match parts with
      | [] ->
        Lwt.fail (Error "Empty path")

      | [ filename ] ->
        let%lwt resolved = resolve_file package filename basedir in
        let%lwt resolved =
          match preprocess, resolved with
          | true, (Module.File {
              filename = Some filename;
              preprocessors;
            }, deps) ->
            let%lwt more_preprocessors, more_deps =
              filename
              |> preprocessor.get_processors
              |> resolve_preprocessors
            in
            Lwt.return (Module.File {
                filename = Some filename;
                preprocessors = more_preprocessors @ preprocessors
              }, more_deps @ deps)
          | _ ->
            Lwt.return resolved
        in
        Lwt.return resolved

      | "-" :: rest
      | "" :: "" :: rest
      | "" :: rest ->
        resolve_parts ~preprocess:false rest

      | _ ->
        let%lwt resolved_file, deps, rest =
          match List.rev parts with
          | [] ->
            Lwt.fail (Error "Verified earlier, empty list cannot get here")
          | "" :: rest ->
            Lwt.return (
              Module.File { filename = None; preprocessors = []},
              [],
              rest
            )
          | filename :: rest ->
            let%lwt resolved_file, deps =
              resolve_parts ~preprocess [filename]
            in
            Lwt.return (resolved_file, deps, rest)
        in
        match resolved_file with
        | Module.Main _ ->
          Lwt.fail (Error "fp$main should never be required")
        | Module.EmptyModule ->
          Lwt.return (Module.EmptyModule, [])
        | Module.Runtime ->
          Lwt.return (Module.Runtime, [])
        | Module.File { preprocessors; filename } ->
          let%lwt more_preprocessors, more_deps = resolve_preprocessors rest in
          Lwt.return (
            Module.File {
              filename;
              preprocessors = more_preprocessors @ preprocessors;
            },
            deps @ more_deps
          )

    in
    let parts = String.split_on_char '!' request in
    resolve_parts parts
  in

  let package_json_cache = ref M.empty in
  let find_package root_dir filename =
    let rec find_package_json dir =
      match M.get dir !package_json_cache with
      | Some package ->
        Lwt.return package
      | None ->
        let filename = FilePath.concat dir "package.json" in
        match%lwt cache.file_exists filename with
        | true ->
          let%lwt package, _ = cache.get_package filename in
          package_json_cache := M.add dir package !package_json_cache;
          Lwt.return package
        | false ->
          if dir = root_dir
          then
            Lwt.return (Package.empty)
          else begin
            let%lwt package = find_package_json (FilePath.dirname dir) in
            package_json_cache := M.add dir package !package_json_cache;
            Lwt.return package
          end
    in
    find_package_json (FilePath.dirname filename)
  in

  { resolve; find_package }

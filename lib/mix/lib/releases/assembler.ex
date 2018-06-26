defmodule Mix.Releases.Assembler do
  @moduledoc """
  This module is responsible for assembling a release based on a `Mix.Releases.Config`
  struct. It creates the release directory, copies applications, and generates release-specific
  files required by `:systools` and `:release_handler`.
  """
  alias Mix.Releases.{Config, Release, Environment, Profile, App}
  alias Mix.Releases.{Utils, Logger, Appup, Plugin, Overlays}

  require Record
  Record.defrecordp(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))

  @doc false
  @spec pre_assemble(Config.t()) :: {:ok, Release.t()} | {:error, term}
  def pre_assemble(%Config{} = config) do
    with {:ok, environment} <- Release.select_environment(config),
         {:ok, release} <- Release.select_release(config),
         release <- apply_environment(release, environment),
         :ok <- validate_configuration(release),
         {:ok, release} <- Release.apply_configuration(release, config, true),
         :ok <- File.mkdir_p(release.profile.output_dir),
         {:ok, release} <- Plugin.before_assembly(release) do
      {:ok, release}
    end
  end

  @doc """
  This function takes a Config struct and assembles the release.

  **Note: This operation has side-effects!** It creates files, directories,
  copies files from other filesystem locations. If failures occur, no cleanup
  of files/directories is performed. However, all files/directories created by
  this function are scoped to the current project's `rel` directory, and cannot
  impact the filesystem outside of this directory.
  """
  @spec assemble(Config.t()) :: {:ok, Release.t()} | {:error, term}
  def assemble(%Config{} = config) do
    with {:ok, release} <- pre_assemble(config),
         {:ok, release} <- generate_overlay_vars(release),
         {:ok, release} <- copy_applications(release),
         :ok <- create_release_info(release),
         {:ok, release} <- apply_overlays(release),
         {:ok, release} <- Plugin.after_assembly(release),
         do: {:ok, release}
  end

  # Applies the environment profile to the release profile.
  @spec apply_environment(Release.t(), Environment.t()) :: {:ok, Release.t()} | {:error, term}
  def apply_environment(%Release{} = r, %Environment{} = e) do
    Logger.info("Building release #{r.name}:#{r.version} using environment #{e.name}")
    Release.apply_environment(r, e)
  end

  @spec validate_configuration(Release.t()) :: :ok | {:error, term}
  def validate_configuration(%Release{} = release) do
    case Release.validate_configuration(release) do
      {:ok, warning} ->
        Logger.notice(warning)
        :ok

      other ->
        other
    end
  end

  # Copies application beams to the output directory
  defp copy_applications(%Release{profile: %Profile{output_dir: output_dir}} = release) do
    Logger.debug("Copying applications to #{output_dir}")

    try do
      File.mkdir_p!(Path.join(output_dir, "lib"))

      for app <- release.applications do
        copy_app(app, release)
      end

      case copy_consolidated(release) do
        :ok ->
          {:ok, release}

        {:error, _} = err ->
          err
      end
    catch
      kind, err ->
        {:error, {:assembler, {kind, err}}}
    end
  end

  # Copy consolidated .beams
  defp copy_consolidated(%Release{profile: %Profile{dev_mode: true}}) do
    :ok
  end

  defp copy_consolidated(%Release{name: name, version: version, profile: profile}) do
    src = Mix.Project.consolidation_path()
    dest = Path.join([profile.output_dir, "lib", "#{name}-#{version}", "consolidated"])
    remove_symlink_or_dir!(dest)
    File.mkdir_p!(dest)

    if File.exists?(src) do
      case File.cp_r(src, dest) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          {:error, {:assembler, :file, {:copy_consolidated, src, dest, reason}}}
      end
    else
      :ok
    end
  end

  # Copies a specific application to the output directory
  defp copy_app(app, %Release{
         profile: %Profile{
           output_dir: output_dir,
           dev_mode: dev_mode?,
           executable: executable?,
           include_src: include_src?,
           include_erts: include_erts?
         }
       }) do
    dev_mode? = if(executable?, do: false, else: dev_mode?)
    app_name = app.name
    app_version = app.vsn
    app_dir = app.path
    lib_dir = Path.join(output_dir, "lib")
    target_dir = Path.join(lib_dir, "#{app_name}-#{app_version}")
    remove_symlink_or_dir!(target_dir)

    case include_erts? do
      true ->
        copy_app(app_dir, target_dir, dev_mode?, include_src?)

      p when is_binary(p) ->
        copy_app(app_dir, target_dir, dev_mode?, include_src?)

      _ ->
        case Utils.is_erts_lib?(app_dir) do
          true ->
            :ok

          false ->
            copy_app(app_dir, target_dir, dev_mode?, include_src?)
        end
    end
  end

  defp copy_app(app_dir, target_dir, true, _include_src?) do
    case File.ln_s(app_dir, target_dir) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, {:assembler, :file, {:copy_app, app_dir, target_dir, reason}}}
    end
  end

  defp copy_app(app_dir, target_dir, false, include_src?) do
    case File.mkdir_p(target_dir) do
      {:error, reason} ->
        {:error, {:assembler, :file, {:copy_app, target_dir, reason}}}

      :ok ->
        valid_dirs =
          cond do
            include_src? ->
              ["ebin", "include", "priv", "lib", "src"]

            :else ->
              ["ebin", "include", "priv"]
          end

        Path.wildcard(Path.join(app_dir, "*"))
        |> Enum.filter(fn p -> Path.basename(p) in valid_dirs end)
        |> Enum.each(fn p ->
          t = Path.join(target_dir, Path.basename(p))

          if symlink?(p) do
            # We need to follow the symlink
            File.mkdir_p!(t)

            Path.wildcard(Path.join(p, "*"))
            |> Enum.each(fn child ->
              tc = Path.join(t, Path.basename(child))

              case File.cp_r(child, tc) do
                {:ok, _} ->
                  :ok

                {:error, reason, file} ->
                  throw({:error, {:assembler, :file, {reason, file}}})
              end
            end)
          else
            case File.cp_r(p, t) do
              {:ok, _} ->
                :ok

              {:error, reason, file} ->
                throw({:error, {:assembler, :file, {reason, file}}})
            end
          end
        end)
    end
  rescue
    e in [File.Error] ->
      {:error, {:assembler, e}}
  catch
    :error, {:assembler, _, _} = err ->
      {:error, err}
  end

  defp remove_symlink_or_dir!(path) do
    case File.exists?(path) do
      true ->
        File.rm_rf!(path)

      false ->
        if symlink?(path) do
          File.rm!(path)
        end
    end

    :ok
  rescue
    e in [File.Error] ->
      {:error, {:assembler, e}}
  end

  defp symlink?(path) do
    case :file.read_link_info('#{path}') do
      {:ok, info} ->
        elem(info, 2) == :symlink

      _ ->
        false
    end
  end

  # Creates release metadata files
  defp create_release_info(%Release{name: relname} = release) do
    output_dir = release.profile.output_dir
    rel_dir = Path.join([output_dir, "releases", "#{release.version}"])

    case File.mkdir_p(rel_dir) do
      {:error, reason} ->
        {:error, {:assembler, :file, {reason, rel_dir}}}

      :ok ->
        release_file = Path.join(rel_dir, "#{relname}.rel")
        start_clean_file = Path.join(rel_dir, "start_clean.rel")

        clean_apps =
          release.applications
          |> Enum.map(fn %{name: n} = a ->
            if not n in [:kernel, :stdlib, :compiler, :elixir, :iex] do
              %{a | start_type: :load}
            else
              a
            end
          end)

        start_clean_rel = %{release | applications: clean_apps}

        with :ok <- write_relfile(release_file, release),
             :ok <- write_relfile(start_clean_file, start_clean_rel),
             :ok <- write_binfile(release, rel_dir),
             :ok <- generate_relup(release, rel_dir),
             do: :ok
    end
  end

  # Creates the .rel file for the release
  defp write_relfile(path, %Release{applications: apps} = release) do
    case get_erts_version(release) do
      {:error, _} = err ->
        err

      {:ok, erts_vsn} ->
        relfile =
          {:release, {'#{release.name}', '#{release.version}'}, {:erts, '#{erts_vsn}'},
           apps
           |> Enum.map(fn %App{name: name, vsn: vsn, start_type: start_type} ->
             case start_type do
               nil ->
                 {name, '#{vsn}'}

               t ->
                 {name, '#{vsn}', t}
             end
           end)}

        Utils.write_term(path, relfile)
    end
  end

  # Creates the .boot files, config files (vm.args, sys.config, config.exs),
  # start_erl.data, release_rc scripts, and includes ERTS into
  # the release if so configured
  defp write_binfile(release, rel_dir) do
    name = "#{release.name}"
    bin_dir = Path.join(release.profile.output_dir, "bin")
    release_rc_entry_path = Path.join(bin_dir, name)
    release_rc_exec_path = Path.join(bin_dir, "#{name}_rc_exec.sh")
    release_rc_main_path = Path.join(rel_dir, "#{name}.sh")
    release_rc_win_exec_path = Path.join(bin_dir, "#{name}.bat")
    release_rc_win_main_path = Path.join(rel_dir, "#{name}.bat")
    template_params = release.profile.overlay_vars

    with :ok <- File.mkdir_p(bin_dir),
         {:ok, release_rc_entry_contents} <- Utils.template(:release_rc_entry, template_params),
         {:ok, release_rc_exec_contents} <- Utils.template(:release_rc_exec, template_params),
         {:ok, release_rc_win_exec_contents} <- Utils.template(:release_rc_win_exec, template_params),
         {:ok, release_rc_main_contents} <- Utils.template(:release_rc_main, template_params),
         {:ok, release_rc_win_main_contents} <- Utils.template(:release_rc_win_main, template_params),
         :ok <- File.write(release_rc_entry_path, release_rc_entry_contents),
         :ok <- File.write(release_rc_exec_path, release_rc_exec_contents),
         :ok <- File.write(release_rc_win_exec_path, release_rc_win_exec_contents),
         :ok <- File.write(release_rc_main_path, release_rc_main_contents),
         :ok <- File.write(release_rc_win_main_path, release_rc_win_main_contents),
         :ok <- File.chmod(release_rc_entry_path, 0o777),
         :ok <- File.chmod(release_rc_exec_path, 0o777),
         :ok <- File.chmod(release_rc_win_exec_path, 0o777),
         :ok <- File.chmod!(release_rc_main_path, 0o777),
         :ok <- File.chmod!(release_rc_win_main_path, 0o777),
         :ok <- generate_start_erl_data(release, rel_dir),
         :ok <- generate_vm_args(release, rel_dir),
         :ok <- generate_config_exs(release, rel_dir),
         :ok <- generate_sys_config(release, rel_dir),
         :ok <- include_erts(release),
         :ok <- make_boot_script(release, rel_dir) do
      :ok
    else
      {:error, {:assembler, _}} = err ->
        err

      {:error, {:assembler, _, _}} = err ->
        err

      {:error, reason, file} ->
        {:error, {:assembler, :file, {reason, file}}}

      {:error, reason} ->
        {:error, {:assembler, reason}}
    end
  end

  # Generates a relup and .appup for all upgraded applications during upgrade releases
  defp generate_relup(%Release{is_upgrade: false}, _rel_dir), do: :ok

  defp generate_relup(%Release{name: name, upgrade_from: upfrom} = release, rel_dir) do
    output_dir = release.profile.output_dir

    Logger.debug("Generating relup for #{name}")

    v1_rel = Path.join([output_dir, "releases", upfrom, "#{name}.rel"])
    v2_rel = Path.join(rel_dir, "#{name}.rel")

    case {File.exists?(v1_rel), File.exists?(v2_rel)} do
      {false, true} ->
        {:error, {:assembler, {:missing_rel, name, upfrom, v1_rel}}}

      {true, false} ->
        {:error, {:assembler, {:missing_rel, name, release.version, v2_rel}}}

      {false, false} ->
        {:error, {:assembler, {:missing_rels, name, upfrom, release.version, v1_rel, v2_rel}}}

      {true, true} ->
        v1_apps = extract_relfile_apps(v1_rel)
        v2_apps = extract_relfile_apps(v2_rel)
        changed = get_changed_apps(v1_apps, v2_apps)
        added = get_added_apps(v2_apps, changed)
        removed = get_removed_apps(v1_apps, v2_apps)

        case generate_appups(release, changed, output_dir) do
          {:error, _} = err ->
            err

          :ok ->
            current_rel = Path.join([output_dir, "releases", release.version, "#{name}"])
            upfrom_rel = Path.join([output_dir, "releases", release.upgrade_from, "#{name}"])

            result =
              :systools.make_relup(
                String.to_charlist(current_rel),
                [String.to_charlist(upfrom_rel)],
                [String.to_charlist(upfrom_rel)],
                [
                  {:outdir, String.to_charlist(rel_dir)},
                  {:path, get_relup_code_paths(added, changed, removed, output_dir)},
                  :silent,
                  :no_warn_sasl
                ]
              )

            case result do
              {:ok, relup, _mod, []} ->
                Logger.info("Relup successfully created")
                Utils.write_term(Path.join(rel_dir, "relup"), relup)

              {:ok, relup, mod, warnings} ->
                Logger.warn(format_systools_warning(mod, warnings))
                Logger.info("Relup successfully created")
                Utils.write_term(Path.join(rel_dir, "relup"), relup)

              {:error, mod, errors} ->
                error = format_systools_error(mod, errors)
                {:error, {:assembler, error}}
            end
        end
    end
  end

  defp format_systools_warning(mod, warnings) do
    warning =
      mod.format_warning(warnings)
      |> IO.iodata_to_binary()
      |> String.split("\n")
      |> Enum.map(fn e -> "    " <> e end)
      |> Enum.join("\n")
      |> String.trim_trailing()

    "#{warning}"
  end

  defp format_systools_error(mod, errors) do
    error =
      mod.format_error(errors)
      |> IO.iodata_to_binary()
      |> String.split("\n")
      |> Enum.map(fn e -> "    " <> e end)
      |> Enum.join("\n")
      |> String.trim_trailing()

    "#{error}"
  end

  # Get a list of applications from the .rel file at the given path
  defp extract_relfile_apps(path) do
    case Utils.read_terms(path) do
      {:error, _} = err ->
        throw(err)

      {:ok, [{:release, _rel, _erts, apps}]} ->
        Enum.map(apps, fn
          {a, v} -> {a, v}
          {a, v, _start_type} -> {a, v}
        end)

      {:ok, other} ->
        throw({:error, {:assembler, {:malformed_relfile, path, other}}})
    end
  end

  # Determine the set of apps which have changed between two versions
  defp get_changed_apps(a, b) do
    as = Enum.map(a, fn app -> elem(app, 0) end) |> MapSet.new()
    bs = Enum.map(b, fn app -> elem(app, 0) end) |> MapSet.new()
    shared = MapSet.to_list(MapSet.intersection(as, bs))
    a_versions = Enum.map(shared, fn n -> {n, elem(List.keyfind(a, n, 0), 1)} end) |> MapSet.new()
    b_versions = Enum.map(shared, fn n -> {n, elem(List.keyfind(b, n, 0), 1)} end) |> MapSet.new()

    MapSet.difference(b_versions, a_versions)
    |> MapSet.to_list()
    |> Enum.map(fn {n, v2} ->
      v1 = List.keyfind(a, n, 0) |> elem(1)
      {n, "#{v1}", "#{v2}"}
    end)
  end

  # Determine the set of apps which were added between two versions
  defp get_added_apps(v2_apps, changed) do
    changed_apps = Enum.map(changed, &elem(&1, 0))

    Enum.reject(v2_apps, fn a ->
      elem(a, 0) in changed_apps
    end)
  end

  # Determine the set of apps removed from v1 to v2
  defp get_removed_apps(a, b) do
    as = Enum.map(a, fn app -> elem(app, 0) end) |> MapSet.new()
    bs = Enum.map(b, fn app -> elem(app, 0) end) |> MapSet.new()

    MapSet.difference(as, bs)
    |> MapSet.to_list()
    |> Enum.map(fn n -> {n, elem(List.keyfind(a, n, 0), 1)} end)
  end

  # Generate .appup files for a list of {app, v1, v2}
  defp generate_appups(_rel, [], _output_dir), do: :ok

  defp generate_appups(release, [{app, v1, v2} | apps], output_dir) do
    v1_path = Path.join([output_dir, "lib", "#{app}-#{v1}"])
    v2_path = Path.join([output_dir, "lib", "#{app}-#{v2}"])
    target_appup_path = Path.join([v2_path, "ebin", "#{app}.appup"])

    appup_path =
      case Appup.locate(app, v1, v2) do
        nil ->
          target_appup_path

        path ->
          File.cp!(path, target_appup_path)
      end

    # Check for existence
    appup_exists? = File.exists?(target_appup_path)

    appup_valid? =
      if appup_exists? do
        case Utils.read_terms(target_appup_path) do
          {:ok, [{v2p, [{v1p, _}], [{v1p, _}]}]} ->
            cond do
              is_binary(v2p) and is_binary(v1p) ->
                # Versions are regular expressions
                v1p = Regex.compile!(v1p)
                v2p = Regex.compile!(v2p)
                String.match?(v1p, v1) and String.match?(v2p, v2)

              v2p == ~c[#{v2}] and v1p == ~c[#{v1}] ->
                true

              :else ->
                false
            end

          _other ->
            false
        end
      else
        false
      end

    cond do
      appup_exists? && appup_valid? ->
        Logger.debug("#{app} requires an appup, and one was provided, skipping generation..")
        generate_appups(release, apps, output_dir)

      appup_exists? ->
        Logger.warn(
          "#{app} has an appup file, but it is invalid for this release,\n" <>
            "    Backing up appfile with .bak extension and generating new one.."
        )

        :ok = File.cp!(target_appup_path, "#{appup_path}.bak")

        case Appup.make(app, v1, v2, v1_path, v2_path, release.profile.appup_transforms) do
          {:error, _} = err ->
            err

          {:ok, appup} ->
            :ok = Utils.write_term(target_appup_path, appup)
            Logger.info("Generated .appup for #{app} #{v1} -> #{v2}")
            generate_appups(release, apps, output_dir)
        end

      :else ->
        Logger.debug(
          "#{app} requires an appup, but it wasn't provided, one will be generated for you.."
        )

        case Appup.make(app, v1, v2, v1_path, v2_path, release.profile.appup_transforms) do
          {:error, _} = err ->
            err

          {:ok, appup} ->
            :ok = Utils.write_term(target_appup_path, appup)
            Logger.info("Generated .appup for #{app} #{v1} -> #{v2}")
            generate_appups(release, apps, output_dir)
        end
    end
  end

  # Get a list of code paths containing only those paths which have beams
  # from the two versions in the release being upgraded
  defp get_relup_code_paths(added, changed, removed, output_dir) do
    added_paths = get_added_relup_code_paths(added, output_dir, [])
    changed_paths = get_changed_relup_code_paths(changed, output_dir, [], [])
    removed_paths = get_removed_relup_code_paths(removed, output_dir, [])
    added_paths ++ changed_paths ++ removed_paths
  end

  defp get_changed_relup_code_paths([], _output_dir, v1_paths, v2_paths) do
    v2_paths ++ v1_paths
  end

  defp get_changed_relup_code_paths([{app, v1, v2} | apps], output_dir, v1_paths, v2_paths) do
    v1_path = Path.join([output_dir, "lib", "#{app}-#{v1}", "ebin"]) |> String.to_charlist()
    v2_path = Path.join([output_dir, "lib", "#{app}-#{v2}", "ebin"]) |> String.to_charlist()

    v2_path_consolidated =
      Path.join([output_dir, "lib", "#{app}-#{v2}", "consolidated"]) |> String.to_charlist()

    get_changed_relup_code_paths(apps, output_dir, [v1_path | v1_paths], [
      v2_path_consolidated,
      v2_path | v2_paths
    ])
  end

  defp get_added_relup_code_paths([], _output_dir, paths), do: paths

  defp get_added_relup_code_paths([{app, v2} | apps], output_dir, paths) do
    v2_path = Path.join([output_dir, "lib", "#{app}-#{v2}", "ebin"]) |> String.to_charlist()

    v2_path_consolidated =
      Path.join([output_dir, "lib", "#{app}-#{v2}", "consolidated"]) |> String.to_charlist()

    get_added_relup_code_paths(apps, output_dir, [v2_path_consolidated, v2_path | paths])
  end

  defp get_removed_relup_code_paths([], _output_dir, paths), do: paths

  defp get_removed_relup_code_paths([{app, v1} | apps], output_dir, paths) do
    v1_path = Path.join([output_dir, "lib", "#{app}-#{v1}", "ebin"]) |> String.to_charlist()

    v1_path_consolidated =
      Path.join([output_dir, "lib", "#{app}-#{v1}", "consolidated"]) |> String.to_charlist()

    get_removed_relup_code_paths(apps, output_dir, [v1_path_consolidated, v1_path | paths])
  end

  # Generates start_erl.data
  defp generate_start_erl_data(%Release{profile: %{include_erts: false}} = rel, rel_dir) do
    Logger.debug("Generating start_erl.data")
    version = rel.version
    contents = "ERTS_VSN #{version}"
    File.write(Path.join([rel_dir, "..", "start_erl.data"]), contents)
  end

  defp generate_start_erl_data(%Release{profile: %Profile{include_erts: path}} = release, rel_dir)
       when is_binary(path) do
    Logger.debug("Generating start_erl.data")

    case Utils.detect_erts_version(path) do
      {:error, _} = err ->
        err

      {:ok, vsn} ->
        contents = "#{vsn} #{release.version}"
        File.write(Path.join([rel_dir, "..", "start_erl.data"]), contents)
    end
  end

  defp generate_start_erl_data(release, rel_dir) do
    Logger.debug("Generating start_erl.data")
    contents = "#{Utils.erts_version()} #{release.version}"
    File.write(Path.join([rel_dir, "..", "start_erl.data"]), contents)
  end

  # Generates vm.args
  defp generate_vm_args(%Release{profile: %Profile{vm_args: nil}} = rel, rel_dir) do
    Logger.debug("Generating vm.args")
    overlay_vars = rel.profile.overlay_vars

    with {:ok, contents} <- Utils.template("vm.args", overlay_vars),
         :ok <- File.write(Path.join(rel_dir, "vm.args"), contents) do
      :ok
    else
      {:error, {:template, _}} = err ->
        err

      {:error, reason} ->
        {:error, {:assembler, :file, reason}}
    end
  end

  defp generate_vm_args(%Release{profile: %Profile{vm_args: path}} = rel, rel_dir) do
    Logger.debug("Generating vm.args from #{Path.relative_to_cwd(path)}")
    overlay_vars = rel.profile.overlay_vars

    with {:ok, path} <- Overlays.template_str(path, overlay_vars),
         {:ok, templated} <- Overlays.template_file(path, overlay_vars),
         :ok <- File.write(Path.join(rel_dir, "vm.args"), templated) do
      :ok
    else
      {:error, {:template, _}} = err ->
        err

      {:error, {:template_str, _}} = err ->
        err

      {:error, reason} ->
        {:error, {:assembler, :file, reason}}
    end
  end

  defp generate_config_exs(%Release{profile: %Profile{config: base_config_path}}, rel_dir) do
    Logger.debug("Generating merged config.exs from #{Path.relative_to_cwd(base_config_path)}")

    merged =
      base_config_path
      |> Mix.Releases.Config.Providers.Elixir.read_quoted!()
      |> Macro.to_string()

    formatted =
      if function_exported?(Code, :format_string!, 1) do
        apply(Code, :format_string!, [merged])
      else
        merged
      end

    case File.write(Path.join(rel_dir, "config.exs"), formatted) do
      :ok ->
        Utils.write_term(Path.join(rel_dir, "sys.config"), [{:sasl, [errlog_type: :error]}])
        :ok

      {:error, reason} ->
        {:error, {:assembler, :file, reason}}
    end
  end

  # Generates sys.config
  defp generate_sys_config(%Release{profile: %Profile{sys_config: config_path}} = rel, rel_dir)
       when is_binary(config_path) do
    Logger.debug("Generating sys.config from #{Path.relative_to_cwd(config_path)}")
    overlay_vars = rel.profile.overlay_vars

    base_config = [
      {:sasl, [errlog_type: :error]},
      {:distillery, [config_providers: rel.profile.config_providers]}
    ]

    res =
      with {:ok, path} <- Overlays.template_str(config_path, overlay_vars),
           {:ok, templated} <- Overlays.template_file(path, overlay_vars),
           {:ok, tokens, _} <- :erl_scan.string(String.to_charlist(templated)),
           {:ok, sys_config} <- :erl_parse.parse_term(tokens),
           :ok <- validate_sys_config(sys_config),
           merged <- Mix.Config.merge(base_config, sys_config),
           final <- append_included_configs(merged, rel.profile.included_configs) do
        Utils.write_term(Path.join(rel_dir, "sys.config"), final)
      end

    case res do
      :ok ->
        :ok

      {:error, {:template, _}} = err ->
        err

      {:error, {:template_str, _}} = err ->
        err

      {:error, {:assembler, _}} = err ->
        err

      {:error, error_info, _end_loc} when is_tuple(error_info) ->
        {:error, {:assembler, {:invalid_sys_config, error_info}}}

      {:error, error_info} when is_tuple(error_info) ->
        {:error, {:assembler, {:invalid_sys_config, error_info}}}
    end
  end

  defp generate_sys_config(%Release{} = rel, rel_dir) do
    Logger.debug("Generating default sys.config with included_configs applied")

    included_configs = rel.profile.included_configs
    config_providers = rel.profile.config_providers

    config =
      [
        {:sasl, [errlog_type: :error]},
        {:distillery, [config_providers: config_providers]}
      ]
      |> append_included_configs(included_configs)

    Utils.write_term(Path.join(rel_dir, "sys.config"), config)
  end

  # Extend the config with the paths of additional config files
  defp append_included_configs(config, []), do: config

  defp append_included_configs(config, configs) when is_list(configs) do
    included_configs = Enum.map(configs, &String.to_charlist/1)
    config ++ included_configs
  end

  defp append_included_configs(_config, _) do
    raise "`included_configs` must be a list of paths"
  end

  defp validate_sys_config(sys_config) when is_list(sys_config) do
    cond do
      Keyword.keyword?(sys_config) ->
        is_config? =
          Enum.reduce(sys_config, true, fn
            {app, config}, acc when is_atom(app) and is_list(config) ->
              acc && Keyword.keyword?(config)

            {_app, _config}, _acc ->
              false
          end)

        cond do
          is_config? ->
            :ok

          :else ->
            {:error, {:assembler, {:invalid_sys_config, :invalid_terms}}}
        end

      :else ->
        {:error, {:assembler, {:invalid_sys_config, :invalid_terms}}}
    end
  end

  defp validate_sys_config(_sys_config),
    do: {:error, {:assembler, {:invalid_sys_config, :invalid_terms}}}

  # Adds ERTS to the release, if so configured
  defp include_erts(%Release{profile: %Profile{include_erts: false}, is_upgrade: false}), do: :ok

  defp include_erts(%Release{profile: %Profile{include_erts: false}, is_upgrade: true}) do
    {:error, {:assembler, :erts_missing_for_upgrades}}
  end

  defp include_erts(%Release{} = release) do
    include_erts = release.profile.include_erts
    output_dir = release.profile.output_dir

    prefix =
      case include_erts do
        true ->
          "#{:code.root_dir()}"

        p when is_binary(p) ->
          Path.expand(p)
      end

    erts_vsn =
      case include_erts do
        true ->
          Utils.erts_version()

        p when is_binary(p) ->
          case Utils.detect_erts_version(prefix) do
            {:ok, vsn} ->
              # verify that the path given was actually the right one
              if File.exists?(Path.join(prefix, "bin")) do
                vsn
              else
                pfx = Path.relative_to_cwd(prefix)
                maybe_path = Path.relative_to_cwd(Path.expand(Path.join(prefix, "..")))
                {:error, {:assembler, {:invalid_erts_path, pfx, maybe_path}}}
              end

            {:error, _} = err ->
              err
          end
      end

    case erts_vsn do
      {:error, _} = err ->
        err

      _ ->
        erts_dir = Path.join([prefix, "erts-#{erts_vsn}"])

        Logger.info("Including ERTS #{erts_vsn} from #{Path.relative_to_cwd(erts_dir)}")

        erts_output_dir = Path.join(output_dir, "erts-#{erts_vsn}")
        erl_path = Path.join([erts_output_dir, "bin", "erl"])
        nodetool_path = Path.join([output_dir, "bin", "nodetool"])
        nodetool_dest = Path.join([erts_output_dir, "bin", "nodetool"])

        with :ok <- remove_if_exists(erts_output_dir),
             :ok <- File.mkdir_p(erts_output_dir),
             {:ok, _} <- File.cp_r(erts_dir, erts_output_dir),
             {:ok, _} <- File.rm_rf(erl_path),
             {:ok, erl_script} <- Utils.template(:erl_script, release.profile.overlay_vars),
             :ok <- File.write(erl_path, erl_script),
             :ok <- File.chmod(erl_path, 0o755),
             :ok <- File.cp(nodetool_path, nodetool_dest),
             :ok <- File.chmod(nodetool_dest, 0o755) do
          :ok
        else
          {:error, reason} ->
            {:error, {:assembler, :file, {:include_erts, reason}}}

          {:error, reason, file} ->
            {:error, {:assembler, :file, {:include_erts, reason, file}}}
        end
    end
  end

  defp remove_if_exists(path) do
    if File.exists?(path) do
      case File.rm_rf(path) do
        {:ok, _} ->
          :ok

        {:error, reason, file} ->
          {:error, {:assembler, :file, {reason, file}}}
      end
    else
      :ok
    end
  end

  # Generates .boot script
  defp make_boot_script(%Release{profile: %Profile{output_dir: output_dir}} = release, rel_dir) do
    Logger.debug("Generating boot script")

    erts_lib_dir =
      case release.profile.include_erts do
        false -> :code.lib_dir()
        true -> :code.lib_dir()
        p -> String.to_charlist(Path.expand(Path.join(p, "lib")))
      end

    options = [
      {:path, ['#{rel_dir}' | Release.get_code_paths(release)]},
      {:outdir, '#{rel_dir}'},
      {:variables, [{'ERTS_LIB_DIR', erts_lib_dir}]},
      :no_warn_sasl,
      :no_module_tests,
      :silent
    ]

    rel_name = '#{release.name}'
    release_file = Path.join(rel_dir, "#{release.name}.rel")
    script_path = Path.join([rel_dir, "#{release.name}.script"])

    case :systools.make_script(rel_name, options) do
      :ok ->
        with :ok <- extend_script(release, script_path),
             :ok <-
               create_RELEASES(
                 output_dir,
                 Path.join(["releases", "#{release.version}", "#{release.name}.rel"])
               ),
             :ok <- create_start_clean(rel_dir, output_dir, options),
             do: :ok

      {:ok, _, []} ->
        with :ok <- extend_script(release, script_path),
             :ok <-
               create_RELEASES(
                 output_dir,
                 Path.join(["releases", "#{release.version}", "#{release.name}.rel"])
               ),
             :ok <- create_start_clean(rel_dir, output_dir, options),
             do: :ok

      :error ->
        {:error, {:assembler, {:make_boot_script, {:unknown, release_file}}}}

      {:ok, mod, warnings} ->
        Logger.warn(format_systools_warning(mod, warnings))
        :ok

      {:error, mod, errors} ->
        error = format_systools_error(mod, errors)
        {:error, {:assembler, {:make_boot_script, error}}}
    end
  end

  # Extend boot script instructions
  defp extend_script(%Release{profile: %Profile{config_providers: providers}}, script_path) do
    alias Mix.Releases.Runtime.Pidfile

    kernel_procs = [
      # Starts the pidfile kernel process
      {:kernelProcess, {Pidfile, {Pidfile, :start, []}}}
    ]

    extras = [
      # Applies the config hook for executing config.exs on boot
      {:apply, {Mix.Releases.Config.Provider, :init, [providers]}}
    ]

    with {:ok, [{:script, {_relname, _relvsn} = header, ixns}]} <- Utils.read_terms(script_path),
         # Inject kernel processes
         {before_app_ctrl, after_app_ctrl} <-
           Enum.split_while(ixns, fn
             {:kernelProcess, {:application_controller, {:application_controller, :start, _}}} -> false
             _ -> true
           end),
         ixns = before_app_ctrl ++ kernel_procs ++ after_app_ctrl,
         # Inject extras after Elixir is started
         {before_elixir, [elixir | after_elixir]} <-
           Enum.split_while(ixns, fn
             {:apply, {:application, :start_boot, [:elixir | _]}} -> false
             _ -> true
           end),
         ixns = before_elixir ++ [elixir | extras] ++ after_elixir,
         # Put script back together
         extended_script = {:script, header, ixns},
         # Write script to .script file
         :ok <- Utils.write_term(script_path, extended_script),
         # Write binary script to .boot file
         boot_path =
           Path.join(Path.dirname(script_path), Path.basename(script_path, ".script") <> ".boot"),
         :ok <- File.write(boot_path, :erlang.term_to_binary(extended_script)) do
      :ok
    else
      {:error, reason} ->
        {:error, {:assembler, {:make_boot_script, reason}}}
    end
  end

  # Generates RELEASES
  defp create_RELEASES(output_dir, relfile) do
    Logger.debug("Generating RELEASES")
    # NOTE: The RELEASES file must contain the correct paths to all libs,
    # including ERTS libs. When include_erts: false, the ERTS path, and thus
    # the paths to all ERTS libs, are not known until runtime. That means the
    # RELEASES file we generate here is invalid, which also means that performing
    # hot upgrades with include_erts: false will fail.
    #
    # This is annoying, but makes sense in the context of how release_handler works,
    # it must be able to handle upgrades where ERTS itself is also upgraded, and that
    # clearly can't happen if there is only one ERTS version (the host). It would be
    # possible to handle this if we could update the release_handler's state after it
    # unpacks a release in order to "fix" the invalid ERTS lib paths, but unfortunately
    # this is not exposed, and short of re-writing release_handler from scratch, there is
    # no work around for this
    old_cwd = File.cwd!()
    File.cd!(output_dir)
    :ok = :release_handler.create_RELEASES('./', 'releases', '#{relfile}', [])
    File.cd!(old_cwd)
    :ok
  end

  # Generates start_clean.boot
  defp create_start_clean(rel_dir, output_dir, options) do
    Logger.debug("Generating start_clean.boot")

    case :systools.make_script('start_clean', options) do
      :ok ->
        with :ok <-
               File.cp(
                 Path.join(rel_dir, "start_clean.boot"),
                 Path.join([output_dir, "bin", "start_clean.boot"])
               ),
             :ok <- File.rm(Path.join(rel_dir, "start_clean.rel")),
             :ok <- File.rm(Path.join(rel_dir, "start_clean.script")) do
          :ok
        else
          {:error, reason} ->
            {:error, {:assembler, :file, {:start_clean, reason}}}
        end

      :error ->
        {:error, {:assembler, {:start_clean, :unknown}}}

      {:ok, _, []} ->
        with :ok <-
               File.cp(
                 Path.join(rel_dir, "start_clean.boot"),
                 Path.join([output_dir, "bin", "start_clean.boot"])
               ),
             :ok <- File.rm(Path.join(rel_dir, "start_clean.rel")),
             :ok <- File.rm(Path.join(rel_dir, "start_clean.script")) do
          :ok
        else
          {:error, reason} ->
            {:error, {:assembler, :file, {:start_clean, reason}}}
        end

      {:ok, mod, warnings} ->
        Logger.warn(format_systools_warning(mod, warnings))
        :ok

      {:error, mod, errors} ->
        error = format_systools_error(mod, errors)
        {:error, {:assembler, {:start_clean, error}}}
    end
  end

  defp apply_overlays(%Release{} = release) do
    Logger.debug("Applying overlays")
    overlay_vars = release.profile.overlay_vars
    hooks_dir = "releases/<%= release_version %>/hooks"
    libexec_source = Path.join("#{:code.priv_dir(:distillery)}", "libexec")

    hook_overlays =
      [
        {:mkdir, hooks_dir},
        {:mkdir, "#{hooks_dir}/pre_configure.d"},
        {:mkdir, "#{hooks_dir}/post_configure.d"},
        {:mkdir, "#{hooks_dir}/pre_start.d"},
        {:mkdir, "#{hooks_dir}/post_start.d"},
        {:mkdir, "#{hooks_dir}/pre_stop.d"},
        {:mkdir, "#{hooks_dir}/post_stop.d"},
        {:mkdir, "#{hooks_dir}/pre_upgrade.d"},
        {:mkdir, "#{hooks_dir}/post_upgrade.d"},
        {:copy, release.profile.pre_configure_hooks, "#{hooks_dir}/pre_configure.d"},
        {:copy, release.profile.post_configure_hooks, "#{hooks_dir}/post_configure.d"},
        {:copy, release.profile.pre_start_hooks, "#{hooks_dir}/pre_start.d"},
        {:copy, release.profile.post_start_hooks, "#{hooks_dir}/post_start.d"},
        {:copy, release.profile.pre_stop_hooks, "#{hooks_dir}/pre_stop.d"},
        {:copy, release.profile.post_stop_hooks, "#{hooks_dir}/post_stop.d"},
        {:copy, release.profile.pre_upgrade_hooks, "#{hooks_dir}/pre_upgrade.d"},
        {:copy, release.profile.post_upgrade_hooks, "#{hooks_dir}/post_upgrade.d"},
        {:copy, libexec_source, "releases/<%= release_version %>/libexec"},
        {:mkdir, "releases/<%= release_version %>/commands"}
        | Enum.map(release.profile.commands, fn {name, path} ->
            ext =
              case Path.extname(path) do
                "" -> ".sh"
                other -> other
              end

            {:copy, path, "releases/<%= release_version %>/commands/#{name}#{ext}"}
          end)
      ]
      |> Enum.filter(fn
        {:copy, nil, _} -> false
        _ -> true
      end)

    output_dir = release.profile.output_dir
    overlays = hook_overlays ++ release.profile.overlays

    case Overlays.apply(output_dir, overlays, overlay_vars) do
      {:ok, paths} ->
        resolved_overlays =
          paths
          |> Enum.map(fn path -> {path, Path.join(output_dir, path)} end)

        release = %{release | resolved_overlays: resolved_overlays}

        {:ok, release}

      {:error, _} = err ->
        err
    end
  end

  defp generate_overlay_vars(release) do
    case get_erts_version(release) do
      {:error, _} = err ->
        err

      {:ok, erts_vsn} ->
        vars =
          [
            release: release,
            release_name: release.name,
            release_version: release.version,
            is_upgrade: release.is_upgrade,
            upgrade_from: release.upgrade_from,
            dev_mode: release.profile.dev_mode,
            include_erts: release.profile.include_erts,
            include_src: release.profile.include_src,
            include_system_libs: release.profile.include_system_libs,
            erl_opts: release.profile.erl_opts,
            run_erl_env: release.profile.run_erl_env,
            erts_vsn: erts_vsn,
            output_dir: release.profile.output_dir
          ] ++ release.profile.overlay_vars

        Logger.debug("Generated overlay vars:")

        inspected =
          vars
          |> Enum.map(fn
            {:release, _} -> nil
            {k, v} -> "#{k}=#{inspect(v)}"
          end)
          |> Enum.reject(&is_nil/1)
          |> Enum.join("\n    ")

        Logger.debug("    #{inspected}", :plain)
        {:ok, %{release | :profile => %{release.profile | :overlay_vars => vars}}}
    end
  end

  @spec get_erts_version(Release.t()) :: {:ok, String.t()} | {:error, term}
  defp get_erts_version(%Release{profile: %Profile{include_erts: path}}) when is_binary(path),
    do: Utils.detect_erts_version(path)

  defp get_erts_version(%Release{profile: %Profile{include_erts: _}}),
    do: {:ok, Utils.erts_version()}
end

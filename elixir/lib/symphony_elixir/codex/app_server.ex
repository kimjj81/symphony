defmodule SymphonyElixir.Codex.AppServer do
  @moduledoc """
  Minimal client for the Codex app-server JSON-RPC 2.0 stream over stdio.
  """

  require Logger
  alias SymphonyElixir.{Codex.DynamicTool, Config, PathSafety, SSH}

  @initialize_id 1
  @thread_start_id 2
  @turn_start_id 3
  @turn_interrupt_id 4
  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000
  @max_orchestration_evidence_bytes 8 * 1024 * 1024
  @non_interactive_tool_input_answer "This is a non-interactive session. Operator input is unavailable."

  @type session :: %{
          port: port(),
          metadata: map(),
          approval_policy: String.t() | map(),
          auto_approve_policy: map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map(),
          worker_tool_policy: :broker_only | :legacy_read_only,
          thread_id: String.t(),
          workspace: Path.t(),
          worker_host: String.t() | nil,
          gh_config_dir: Path.t() | nil,
          orchestration_evidence_path: Path.t() | nil
        }

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <- start_session(workspace, opts) do
      try do
        run_turn(session, prompt, issue, opts)
      after
        stop_session(session)
      end
    end
  end

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    codex_command = Keyword.get(opts, :codex_command) || Config.settings!().codex.command
    worker_tool_policy = Keyword.get(opts, :worker_tool_policy, :broker_only)
    orchestration_evidence = Keyword.get(opts, :orchestration_evidence)

    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host),
         :ok <- validate_worker_tool_policy(worker_tool_policy),
         {:ok, port, gh_config_dir, evidence_path} <-
           start_port(expanded_workspace, worker_host, codex_command, orchestration_evidence) do
      metadata = port_metadata(port, worker_host)

      with {:ok, session_policies} <- session_policies(expanded_workspace, worker_host, opts),
           session_policies <- Map.put(session_policies, :worker_tool_policy, worker_tool_policy),
           {:ok, thread_id} <- do_start_session(port, expanded_workspace, session_policies) do
        {:ok,
         %{
           port: port,
           metadata: metadata,
           approval_policy: session_policies.approval_policy,
           auto_approve_policy: auto_approve_policy(session_policies),
           thread_sandbox: session_policies.thread_sandbox,
           turn_sandbox_policy: session_policies.turn_sandbox_policy,
           worker_tool_policy: worker_tool_policy,
           thread_id: thread_id,
           workspace: expanded_workspace,
           worker_host: worker_host,
           gh_config_dir: gh_config_dir,
           orchestration_evidence_path: evidence_path
         }}
      else
        {:error, reason} ->
          stop_port(port)
          remove_worker_gh_config_dir(gh_config_dir)
          {:error, reason}
      end
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{
          port: port,
          metadata: metadata,
          approval_policy: approval_policy,
          turn_sandbox_policy: turn_sandbox_policy,
          worker_tool_policy: worker_tool_policy,
          thread_id: thread_id,
          workspace: workspace
        } = session,
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)

    tool_executor = Keyword.get(opts, :tool_executor, default_tool_executor(worker_tool_policy))
    tool_policy = Keyword.get(opts, :tool_policy, :allow)

    with :ok <- validate_turn_tool_policy(tool_policy) do
      case start_turn(
             port,
             thread_id,
             prompt,
             issue,
             workspace,
             approval_policy,
             turn_sandbox_policy,
             opts
           ) do
        {:ok, turn_id} ->
          session_id = "#{thread_id}-#{turn_id}"
          Logger.info("Codex session started for #{issue_context(issue)} session_id=#{session_id}")

          emit_message(
            on_message,
            :session_started,
            %{
              session_id: session_id,
              thread_id: thread_id,
              turn_id: turn_id
            },
            metadata
          )

          finish_turn(
            session,
            issue,
            turn_id,
            tool_executor,
            tool_policy,
            on_message
          )

        {:error, reason} ->
          Logger.error("Codex session failed for #{issue_context(issue)}: #{inspect(reason)}")
          emit_message(on_message, :startup_failed, %{reason: reason}, metadata)
          {:error, reason}
      end
    end
  end

  defp finish_turn(
         %{
           port: port,
           thread_id: thread_id,
           auto_approve_policy: auto_approve_policy,
           metadata: metadata
         },
         issue,
         turn_id,
         tool_executor,
         tool_policy,
         on_message
       ) do
    session_id = "#{thread_id}-#{turn_id}"

    case await_turn_completion(
           port,
           on_message,
           tool_executor,
           auto_approve_policy,
           thread_id,
           turn_id,
           tool_policy
         ) do
      {:ok, result, final_agent_message} ->
        Logger.info("Codex session completed for #{issue_context(issue)} session_id=#{session_id}")

        {:ok,
         %{
           result: result,
           final_agent_message: final_agent_message,
           session_id: session_id,
           thread_id: thread_id,
           turn_id: turn_id
         }}

      {:error, reason} ->
        Logger.warning("Codex session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")

        emit_message(
          on_message,
          :turn_ended_with_error,
          %{
            session_id: session_id,
            reason: reason
          },
          metadata
        )

        {:error, reason}
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{port: port, gh_config_dir: gh_config_dir}) when is_port(port) do
    stop_port(port)
    remove_worker_gh_config_dir(gh_config_dir)
  end

  defp validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        source_checkout_cwd?(canonical_workspace) ->
          {:ok, canonical_workspace}

        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  defp source_checkout_cwd?(canonical_workspace) when is_binary(canonical_workspace) do
    case Config.settings!().workspace.source do
      source when is_binary(source) and source != "" ->
        case PathSafety.canonicalize(Path.expand(source)) do
          {:ok, canonical_source} -> canonical_workspace == canonical_source
          {:error, _reason} -> false
        end

      _ ->
        false
    end
  end

  defp start_port(workspace, nil, codex_command, orchestration_evidence) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      gh_config_dir = worker_gh_config_dir()
      :ok = File.mkdir_p(gh_config_dir)
      :ok = File.chmod(gh_config_dir, 0o700)

      case prepare_local_orchestration_evidence(gh_config_dir, orchestration_evidence) do
        {:ok, evidence_path} ->
          port =
            Port.open(
              {:spawn_executable, String.to_charlist(executable)},
              [
                :binary,
                :exit_status,
                :stderr_to_stdout,
                args: [~c"-lc", String.to_charlist(local_worker_command(codex_command))],
                cd: String.to_charlist(workspace),
                env: worker_environment(gh_config_dir, evidence_path),
                line: @port_line_bytes
              ]
            )

          {:ok, port, gh_config_dir, evidence_path}

        {:error, reason} ->
          remove_worker_gh_config_dir(gh_config_dir)
          {:error, reason}
      end
    end
  end

  defp start_port(workspace, worker_host, codex_command, orchestration_evidence)
       when is_binary(worker_host) do
    gh_config_dir = worker_gh_config_dir("/tmp")

    with {:ok, evidence_path} <-
           prepare_remote_orchestration_evidence(worker_host, gh_config_dir, orchestration_evidence) do
      remote_command = remote_launch_command(workspace, codex_command, gh_config_dir, evidence_path)

      case SSH.start_port(worker_host, remote_command, line: @port_line_bytes) do
        {:ok, port} ->
          {:ok, port, nil, evidence_path}

        {:error, reason} ->
          cleanup_remote_worker_runtime(worker_host, gh_config_dir)
          {:error, reason}
      end
    end
  end

  defp remote_launch_command(workspace, codex_command, gh_config_dir, evidence_path)
       when is_binary(workspace) do
    [
      "cd #{shell_escape(workspace)}",
      "umask 077",
      "mkdir -p #{shell_escape(gh_config_dir)}",
      "trap 'rm -rf -- #{gh_config_dir}' EXIT",
      "#{remote_worker_environment(gh_config_dir, evidence_path)} #{codex_command}"
    ]
    |> Enum.join(" && ")
  end

  defp worker_environment(gh_config_dir, evidence_path) do
    scrubbed =
      worker_write_token_envs()
      |> Enum.map(&{String.to_charlist(&1), false})

    base =
      [
        {~c"GH_CONFIG_DIR", String.to_charlist(gh_config_dir)},
        {~c"GIT_TERMINAL_PROMPT", ~c"0"}
      ] ++ evidence_environment(evidence_path) ++ worker_cache_environment(gh_config_dir) ++ scrubbed

    base
  end

  # Port environment entries with an empty value unset the variable. Git needs
  # the empty value to reset credential helpers, so inject it through the shell
  # that launches the local worker instead.
  defp local_worker_command(codex_command) do
    "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0='' #{codex_command}"
  end

  defp remote_worker_environment(gh_config_dir, evidence_path) do
    # Names were validated by worker_write_token_envs/0, so they can be emitted
    # as shell identifiers without quoting while preserving a readable command.
    unset = "env" <> Enum.map_join(worker_write_token_envs(), "", &" -u #{&1}")
    config_dir = "GH_CONFIG_DIR=#{shell_escape(gh_config_dir)}"
    cache_environment = remote_worker_cache_environment(gh_config_dir)
    evidence_environment = remote_evidence_environment(evidence_path)

    git_credentials =
      "GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=''"

    # SSH exposes the remote command to local process inspection. Workers use
    # the broker-owned immutable tracker snapshot, so neither local nor remote
    # workers receive tracker credentials.
    Enum.join([unset, config_dir, cache_environment, evidence_environment, git_credentials], " ")
  end

  defp evidence_environment(path) when is_binary(path),
    do: [{~c"SYMPHONY_ORCHESTRATION_EVIDENCE", String.to_charlist(path)}]

  defp evidence_environment(_path), do: []

  defp remote_evidence_environment(path) when is_binary(path),
    do: "SYMPHONY_ORCHESTRATION_EVIDENCE=#{shell_escape(path)}"

  defp remote_evidence_environment(_path), do: ""

  defp prepare_local_orchestration_evidence(_runtime_dir, nil), do: {:ok, nil}

  defp prepare_local_orchestration_evidence(runtime_dir, evidence) when is_map(evidence) do
    with {:ok, payload} <- validate_orchestration_evidence(evidence),
         path = Path.join(runtime_dir, payload.filename),
         :ok <- File.write(path, payload.content, [:binary, :exclusive]),
         :ok <- File.chmod(path, 0o400),
         {:ok, written} <- File.read(path),
         :ok <- verify_orchestration_evidence(written, payload) do
      {:ok, path}
    else
      {:error, reason} -> {:error, {:orchestration_evidence_write_failed, reason}}
    end
  end

  defp prepare_local_orchestration_evidence(_runtime_dir, _evidence),
    do: {:error, {:orchestration_evidence_write_failed, :invalid_orchestration_evidence}}

  defp prepare_remote_orchestration_evidence(_worker_host, _runtime_dir, nil), do: {:ok, nil}

  defp prepare_remote_orchestration_evidence(worker_host, runtime_dir, evidence)
       when is_map(evidence) do
    with {:ok, payload} <- validate_orchestration_evidence(evidence),
         :ok <- create_remote_worker_runtime(worker_host, runtime_dir),
         remote_path = Path.join(runtime_dir, payload.filename),
         :ok <- copy_remote_orchestration_evidence(worker_host, remote_path, payload),
         :ok <- verify_remote_orchestration_evidence(worker_host, remote_path, payload) do
      {:ok, remote_path}
    else
      {:error, reason} ->
        cleanup_remote_worker_runtime(worker_host, runtime_dir)
        {:error, {:orchestration_evidence_upload_failed, reason}}
    end
  end

  defp prepare_remote_orchestration_evidence(_worker_host, _runtime_dir, _evidence),
    do: {:error, {:orchestration_evidence_upload_failed, :invalid_orchestration_evidence}}

  defp validate_orchestration_evidence(evidence) do
    filename = Map.get(evidence, :filename) || Map.get(evidence, "filename")
    content = Map.get(evidence, :content) || Map.get(evidence, "content")
    bytes = Map.get(evidence, :bytes) || Map.get(evidence, "bytes")
    digest = Map.get(evidence, :sha256) || Map.get(evidence, "sha256")

    with :ok <- validate_evidence_filename(filename),
         :ok <- validate_evidence_content(content),
         :ok <- validate_evidence_size(content, bytes),
         :ok <- validate_evidence_digest(content, digest) do
      {:ok, %{filename: filename, content: content, bytes: bytes, sha256: digest}}
    end
  end

  defp validate_evidence_filename(filename)
       when is_binary(filename) and filename != "" do
    if Path.basename(filename) == filename,
      do: :ok,
      else: {:error, :invalid_orchestration_evidence_filename}
  end

  defp validate_evidence_filename(_filename),
    do: {:error, :invalid_orchestration_evidence_filename}

  defp validate_evidence_content(content) when is_binary(content), do: :ok
  defp validate_evidence_content(_content), do: {:error, :invalid_orchestration_evidence_content}

  defp validate_evidence_size(content, bytes) when is_binary(content) and is_integer(bytes) do
    cond do
      bytes != byte_size(content) ->
        {:error, :orchestration_evidence_size_mismatch}

      bytes > @max_orchestration_evidence_bytes ->
        {:error, {:orchestration_evidence_too_large, bytes}}

      true ->
        :ok
    end
  end

  defp validate_evidence_size(_content, _bytes), do: {:error, :orchestration_evidence_size_mismatch}

  defp validate_evidence_digest(content, digest)
       when is_binary(content) and is_binary(digest) do
    if digest == sha256(content),
      do: :ok,
      else: {:error, :orchestration_evidence_digest_mismatch}
  end

  defp validate_evidence_digest(_content, _digest),
    do: {:error, :orchestration_evidence_digest_mismatch}

  defp verify_orchestration_evidence(content, payload) do
    if byte_size(content) == payload.bytes and sha256(content) == payload.sha256 do
      :ok
    else
      {:error, :orchestration_evidence_verification_failed}
    end
  end

  defp create_remote_worker_runtime(worker_host, runtime_dir) do
    command = "umask 077 && mkdir -p #{shell_escape(runtime_dir)} && chmod 700 #{shell_escape(runtime_dir)}"

    case SSH.run(worker_host, command, stderr_to_stdout: true) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {output, status}} -> {:error, {:remote_runtime_create_failed, status, output}}
      {:error, reason} -> {:error, {:remote_runtime_create_failed, reason}}
    end
  end

  defp copy_remote_orchestration_evidence(worker_host, remote_path, payload) do
    staging_path =
      Path.join(
        System.tmp_dir!(),
        "symphony-orchestration-evidence-#{System.unique_integer([:positive, :monotonic])}.yaml"
      )

    try do
      with :ok <- File.write(staging_path, payload.content, [:binary, :exclusive]),
           :ok <- File.chmod(staging_path, 0o600),
           {:ok, {_output, 0}} <-
             SSH.copy_to(worker_host, staging_path, remote_path, stderr_to_stdout: true) do
        :ok
      else
        {:ok, {output, status}} -> {:error, {:remote_evidence_copy_failed, status, output}}
        {:error, reason} -> {:error, {:remote_evidence_copy_failed, reason}}
      end
    after
      File.rm(staging_path)
    end
  end

  defp verify_remote_orchestration_evidence(worker_host, remote_path, payload) do
    escaped_path = shell_escape(remote_path)

    command =
      [
        """
        test "$(wc -c < #{escaped_path} | tr -d ' ')" = "#{payload.bytes}"
        """,
        """
        test "$(sha256sum #{escaped_path} | cut -d' ' -f1)" = "#{payload.sha256}"
        """,
        "chmod 400 #{escaped_path}"
      ]
      |> Enum.map_join(" && ", &String.trim/1)

    case SSH.run(worker_host, command, stderr_to_stdout: true) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {output, status}} -> {:error, {:remote_evidence_verification_failed, status, output}}
      {:error, reason} -> {:error, {:remote_evidence_verification_failed, reason}}
    end
  end

  defp cleanup_remote_worker_runtime(worker_host, runtime_dir) do
    command = "rm -rf -- #{shell_escape(runtime_dir)}"
    _ = SSH.run(worker_host, command, stderr_to_stdout: true)
    :ok
  end

  defp worker_cache_environment(gh_config_dir) do
    gh_config_dir
    |> worker_cache_paths()
    |> Enum.map(fn {name, path} ->
      {String.to_charlist(name), String.to_charlist(path)}
    end)
  end

  defp remote_worker_cache_environment(gh_config_dir) do
    gh_config_dir
    |> worker_cache_paths()
    |> Enum.map_join(" ", fn {name, path} -> "#{name}=#{shell_escape(path)}" end)
  end

  defp worker_cache_paths(gh_config_dir) do
    cache_root = Path.join(gh_config_dir, "cache")

    [
      {"XDG_CACHE_HOME", Path.join(cache_root, "xdg")},
      {"UV_CACHE_DIR", Path.join(cache_root, "uv")},
      {"MYVEN_GITLEAKS_CACHE_DIR", Path.join(cache_root, "gitleaks")}
    ]
  end

  defp worker_write_token_envs do
    tracker = Config.settings!().tracker
    configured = tracker.read_api_key_envs ++ tracker.write_api_key_envs

    (~w(GITHUB_TOKEN GH_TOKEN FORGEJO_TOKEN SYMPHONY_TRACKER_READ_TOKEN SYMPHONY_TRACKER_WRITE_TOKEN LINEAR_API_KEY SYMPHONY_FORGEJO_WEBHOOK_SECRET SYMPHONY_GITHUB_WEBHOOK_SECRET) ++
       configured)
    |> Enum.filter(&valid_environment_name?/1)
    |> Enum.uniq()
  end

  defp valid_environment_name?(name) when is_binary(name),
    do: String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)

  defp valid_environment_name?(_name), do: false

  defp worker_gh_config_dir(root \\ System.tmp_dir!()) do
    Path.join(root, "symphony-worker-gh-config-#{System.unique_integer([:positive, :monotonic])}")
  end

  defp remove_worker_gh_config_dir(path) when is_binary(path),
    do: File.rm_rf(path) |> then(fn _ -> :ok end)

  defp remove_worker_gh_config_dir(_path), do: :ok

  defp sha256(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end

  defp port_metadata(port, worker_host) when is_port(port) do
    base_metadata =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} ->
          %{codex_app_server_pid: to_string(os_pid)}

        _ ->
          %{}
      end

    case worker_host do
      host when is_binary(host) -> Map.put(base_metadata, :worker_host, host)
      _ -> base_metadata
    end
  end

  defp send_initialize(port) do
    payload = %{
      "method" => "initialize",
      "id" => @initialize_id,
      "params" => %{
        "capabilities" => %{
          "experimentalApi" => true
        },
        "clientInfo" => %{
          "name" => "symphony-orchestrator",
          "title" => "Symphony Orchestrator",
          "version" => "0.1.0"
        }
      }
    }

    send_message(port, payload)

    with {:ok, _} <- await_response(port, @initialize_id) do
      send_message(port, %{"method" => "initialized", "params" => %{}})
      :ok
    end
  end

  defp session_policies(workspace, nil, opts) do
    with {:ok, settings} <- Config.codex_runtime_settings(workspace) do
      {:ok, merge_runtime_overrides(settings, Keyword.get(opts, :runtime_overrides, %{}))}
    end
  end

  defp session_policies(workspace, worker_host, opts) when is_binary(worker_host) do
    with {:ok, settings} <- Config.codex_runtime_settings(workspace, remote: true) do
      {:ok, merge_runtime_overrides(settings, Keyword.get(opts, :runtime_overrides, %{}))}
    end
  end

  defp merge_runtime_overrides(settings, overrides) when is_map(overrides) do
    Map.merge(settings, overrides)
  end

  defp merge_runtime_overrides(settings, _overrides), do: settings

  defp validate_worker_tool_policy(policy) when policy in [:broker_only, :legacy_read_only],
    do: :ok

  defp validate_worker_tool_policy(policy), do: {:error, {:invalid_worker_tool_policy, policy}}

  defp validate_turn_tool_policy(policy) when policy in [:allow, :deny_and_interrupt], do: :ok
  defp validate_turn_tool_policy(policy), do: {:error, {:invalid_turn_tool_policy, policy}}

  defp default_tool_executor(:legacy_read_only), do: &DynamicTool.execute/2
  defp default_tool_executor(:broker_only), do: &reject_worker_dynamic_tool/2

  defp auto_approve_policy(%{approval_policy: approval_policy} = session_policies) do
    auto_approve_all =
      case Map.get(session_policies, :auto_approve_requests) do
        value when is_boolean(value) -> value
        _ -> approval_policy == "never"
      end

    command_patterns =
      session_policies
      |> Map.get(:auto_approve_command_patterns, [])
      |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))

    %{all: auto_approve_all, command_patterns: command_patterns}
  end

  defp do_start_session(port, workspace, session_policies) do
    case send_initialize(port) do
      :ok -> start_thread(port, workspace, session_policies)
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_thread(port, workspace, %{
         approval_policy: approval_policy,
         thread_sandbox: thread_sandbox,
         worker_tool_policy: worker_tool_policy
       }) do
    send_message(port, %{
      "method" => "thread/start",
      "id" => @thread_start_id,
      "params" => %{
        "approvalPolicy" => approval_policy,
        "sandbox" => thread_sandbox,
        "cwd" => workspace,
        "dynamicTools" => worker_dynamic_tools(worker_tool_policy)
      }
    })

    case await_response(port, @thread_start_id) do
      {:ok, %{"thread" => thread_payload}} ->
        case thread_payload do
          %{"id" => thread_id} -> {:ok, thread_id}
          _ -> {:error, {:invalid_thread_payload, thread_payload}}
        end

      other ->
        other
    end
  end

  defp worker_dynamic_tools(:legacy_read_only), do: DynamicTool.tool_specs()
  defp worker_dynamic_tools(:broker_only), do: []

  defp start_turn(
         port,
         thread_id,
         prompt,
         issue,
         workspace,
         approval_policy,
         turn_sandbox_policy,
         opts
       ) do
    sandbox_policy = Keyword.get(opts, :sandbox_policy, turn_sandbox_policy)

    params =
      %{
        "threadId" => thread_id,
        "input" => [
          %{
            "type" => "text",
            "text" => prompt
          }
        ],
        "cwd" => workspace,
        "title" => "#{issue.identifier}: #{issue.title}",
        "approvalPolicy" => approval_policy,
        "sandboxPolicy" => sandbox_policy
      }
      |> put_optional_param("model", Keyword.get(opts, :model))
      |> put_optional_param("effort", Keyword.get(opts, :effort))
      |> put_optional_param("outputSchema", Keyword.get(opts, :output_schema))

    send_message(port, %{
      "method" => "turn/start",
      "id" => @turn_start_id,
      "params" => params
    })

    case await_response(port, @turn_start_id) do
      {:ok, %{"turn" => %{"id" => turn_id}}} -> {:ok, turn_id}
      other -> other
    end
  end

  defp put_optional_param(params, _key, nil), do: params
  defp put_optional_param(params, key, value), do: Map.put(params, key, value)

  defp reject_worker_dynamic_tool(tool, _arguments) do
    output =
      Jason.encode!(%{
        "error" => %{
          "message" => "Unsupported dynamic tool: #{inspect(tool)}.",
          "supportedTools" => []
        }
      })

    %{
      "success" => false,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end

  @doc false
  @spec final_agent_message(map()) :: String.t() | nil
  def final_agent_message(%{
        "method" => "item/completed",
        "params" => %{"item" => %{"type" => "agentMessage", "text" => text}}
      })
      when is_binary(text),
      do: text

  def final_agent_message(%{"params" => %{"turn" => %{"items" => items}}}) when is_list(items) do
    items
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{"type" => "agentMessage", "text" => text} when is_binary(text) -> text
      _ -> nil
    end)
  end

  def final_agent_message(_payload), do: nil

  defp await_turn_completion(
         port,
         on_message,
         tool_executor,
         auto_approve_requests,
         thread_id,
         turn_id,
         tool_policy
       ) do
    receive_loop(
      port,
      on_message,
      Config.settings!().codex.turn_timeout_ms,
      "",
      tool_executor,
      %{
        auto_approve_requests: auto_approve_requests,
        last_agent_message: nil,
        last_agent_message_scoped: false,
        thread_id: thread_id,
        turn_id: turn_id,
        tool_policy: tool_policy
      }
    )
  end

  defp receive_loop(
         port,
         on_message,
         timeout_ms,
         pending_line,
         tool_executor,
         stream_state
       ) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)

        handle_incoming(
          port,
          on_message,
          complete_line,
          timeout_ms,
          tool_executor,
          stream_state
        )

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(
          port,
          on_message,
          timeout_ms,
          pending_line <> to_string(chunk),
          tool_executor,
          stream_state
        )

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :turn_timeout}
    end
  end

  defp handle_incoming(
         port,
         on_message,
         data,
         timeout_ms,
         tool_executor,
         stream_state
       ) do
    payload_string = to_string(data)

    case Jason.decode(payload_string) do
      {:ok, %{"method" => "turn/completed"} = payload} ->
        handle_terminal_turn_message(
          :completed,
          port,
          on_message,
          payload,
          payload_string,
          timeout_ms,
          tool_executor,
          stream_state
        )

      {:ok, %{"method" => "turn/failed", "params" => _} = payload} ->
        handle_terminal_turn_message(
          :failed,
          port,
          on_message,
          payload,
          payload_string,
          timeout_ms,
          tool_executor,
          stream_state
        )

      {:ok, %{"method" => "turn/cancelled", "params" => _} = payload} ->
        handle_terminal_turn_message(
          :cancelled,
          port,
          on_message,
          payload,
          payload_string,
          timeout_ms,
          tool_executor,
          stream_state
        )

      {:ok, %{"method" => method} = payload}
      when is_binary(method) ->
        stream_state = update_stream_state(stream_state, payload)

        handle_turn_method(
          port,
          on_message,
          payload,
          payload_string,
          method,
          timeout_ms,
          tool_executor,
          stream_state
        )

      {:ok, payload} ->
        emit_message(
          on_message,
          :other_message,
          %{
            payload: payload,
            raw: payload_string
          },
          metadata_from_message(port, payload)
        )

        receive_loop(
          port,
          on_message,
          timeout_ms,
          "",
          tool_executor,
          stream_state
        )

      {:error, _reason} ->
        log_non_json_stream_line(payload_string, "turn stream")

        if protocol_message_candidate?(payload_string) do
          emit_message(
            on_message,
            :malformed,
            %{
              payload: payload_string,
              raw: payload_string
            },
            metadata_from_message(port, %{raw: payload_string})
          )
        end

        receive_loop(
          port,
          on_message,
          timeout_ms,
          "",
          tool_executor,
          stream_state
        )
    end
  end

  defp handle_terminal_turn_message(
         terminal_kind,
         port,
         on_message,
         payload,
         payload_string,
         timeout_ms,
         tool_executor,
         stream_state
       ) do
    if current_turn_message?(payload, stream_state) do
      complete_terminal_turn_message(
        terminal_kind,
        port,
        on_message,
        payload,
        payload_string,
        stream_state
      )
    else
      continue_after_foreign_turn_message(
        port,
        on_message,
        payload,
        payload_string,
        timeout_ms,
        tool_executor,
        stream_state
      )
    end
  end

  defp complete_terminal_turn_message(
         :completed,
         port,
         on_message,
         payload,
         payload_string,
         stream_state
       ) do
    handle_completed_turn(port, on_message, payload, payload_string, stream_state)
  end

  defp complete_terminal_turn_message(
         terminal_kind,
         port,
         on_message,
         payload,
         payload_string,
         _stream_state
       )
       when terminal_kind in [:failed, :cancelled] do
    {event, reason} =
      case terminal_kind do
        :failed -> {:turn_failed, :turn_failed}
        :cancelled -> {:turn_cancelled, :turn_cancelled}
      end

    params = Map.get(payload, "params")
    emit_turn_event(on_message, event, payload, payload_string, port, params)
    {:error, {reason, params}}
  end

  defp emit_turn_event(on_message, event, payload, payload_string, port, payload_details) do
    emit_message(
      on_message,
      event,
      %{
        payload: payload,
        raw: payload_string,
        details: payload_details
      },
      metadata_from_message(port, payload)
    )
  end

  defp handle_turn_method(
         port,
         on_message,
         payload,
         payload_string,
         method,
         timeout_ms,
         tool_executor,
         stream_state
       ) do
    if forbidden_tool_activity?(method, payload, stream_state) do
      interrupt_forbidden_tool_activity(
        port,
        on_message,
        payload,
        payload_string,
        method,
        timeout_ms,
        tool_executor,
        stream_state
      )
    else
      handle_allowed_turn_method(
        port,
        on_message,
        payload,
        payload_string,
        method,
        timeout_ms,
        tool_executor,
        stream_state
      )
    end
  end

  defp handle_allowed_turn_method(
         port,
         on_message,
         payload,
         payload_string,
         method,
         timeout_ms,
         tool_executor,
         stream_state
       ) do
    metadata = metadata_from_message(port, payload)

    case maybe_handle_approval_request(
           port,
           method,
           payload,
           payload_string,
           on_message,
           metadata,
           tool_executor,
           stream_state.auto_approve_requests
         ) do
      :input_required ->
        emit_message(
          on_message,
          :turn_input_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:turn_input_required, payload}}

      :approved ->
        receive_loop(
          port,
          on_message,
          timeout_ms,
          "",
          tool_executor,
          stream_state
        )

      :approval_required ->
        emit_message(
          on_message,
          :approval_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:approval_required, payload}}

      :unhandled ->
        if needs_input?(method, payload) do
          emit_message(
            on_message,
            :turn_input_required,
            %{payload: payload, raw: payload_string},
            metadata
          )

          {:error, {:turn_input_required, payload}}
        else
          emit_message(
            on_message,
            :notification,
            %{
              payload: payload,
              raw: payload_string
            },
            metadata
          )

          Logger.debug("Codex notification: #{inspect(method)}")

          receive_loop(
            port,
            on_message,
            timeout_ms,
            "",
            tool_executor,
            stream_state
          )
        end
    end
  end

  defp forbidden_tool_activity?(_method, _payload, %{tool_policy: :allow}), do: false

  defp forbidden_tool_activity?(method, payload, %{
         tool_policy: :deny_and_interrupt
       }) do
    forbidden_tool_method?(method, payload)
  end

  defp forbidden_tool_method?(method, _payload)
       when method in [
              "item/commandExecution/requestApproval",
              "item/fileChange/requestApproval",
              "item/tool/call",
              "item/tool/requestUserInput",
              "item/permissions/requestApproval",
              "execCommandApproval",
              "applyPatchApproval",
              "mcpServer/elicitation/request",
              "tool/requestUserInput",
              "codex/event/exec_command_begin",
              "item/commandExecution/started",
              "item/fileChange/started",
              "item/mcpToolCall/started",
              "item/dynamicToolCall/started",
              "item/webSearch/started"
            ],
       do: true

  defp forbidden_tool_method?("item/started", payload) do
    get_in(payload, ["params", "item", "type"]) in [
      "commandExecution",
      "fileChange",
      "mcpToolCall",
      "dynamicToolCall",
      "webSearch",
      "imageGeneration"
    ]
  end

  defp forbidden_tool_method?(_method, _payload), do: false

  defp interrupt_forbidden_tool_activity(
         port,
         on_message,
         payload,
         payload_string,
         method,
         timeout_ms,
         tool_executor,
         stream_state
       ) do
    if current_turn_message?(payload, stream_state) do
      send_message(port, %{
        "method" => "turn/interrupt",
        "id" => @turn_interrupt_id,
        "params" => %{
          "threadId" => stream_state.thread_id,
          "turnId" => stream_state.turn_id
        }
      })

      emit_message(
        on_message,
        :forbidden_tool_call,
        %{payload: payload, raw: payload_string, method: method},
        metadata_from_message(port, payload)
      )

      {:error, {:forbidden_tool_call, method}}
    else
      continue_after_foreign_turn_message(
        port,
        on_message,
        payload,
        payload_string,
        timeout_ms,
        tool_executor,
        stream_state
      )
    end
  end

  defp update_stream_state(stream_state, payload) do
    if current_turn_message?(payload, stream_state) do
      case final_agent_message(payload) do
        message when is_binary(message) ->
          %{
            stream_state
            | last_agent_message: message,
              last_agent_message_scoped: scoped_turn_message?(payload)
          }

        nil ->
          stream_state
      end
    else
      stream_state
    end
  end

  defp current_turn_message?(payload, stream_state) do
    params = Map.get(payload, "params", %{})
    message_thread_id = Map.get(params, "threadId")
    message_turn_id = Map.get(params, "turnId") || get_in(params, ["turn", "id"])

    matches_identifier?(message_thread_id, stream_state.thread_id) and
      matches_identifier?(message_turn_id, stream_state.turn_id)
  end

  # Older app-server versions and test doubles omitted notification identifiers.
  # Treat an absent identifier as compatible, but reject every explicit mismatch.
  defp matches_identifier?(nil, _expected), do: true
  defp matches_identifier?(actual, expected), do: actual == expected

  defp scoped_turn_message?(payload) do
    params = Map.get(payload, "params", %{})

    is_binary(Map.get(params, "threadId")) and
      is_binary(Map.get(params, "turnId") || get_in(params, ["turn", "id"]))
  end

  defp continue_after_foreign_turn_message(
         port,
         on_message,
         payload,
         payload_string,
         timeout_ms,
         tool_executor,
         stream_state
       ) do
    emit_message(
      on_message,
      :notification,
      %{payload: payload, raw: payload_string},
      metadata_from_message(port, payload)
    )

    receive_loop(port, on_message, timeout_ms, "", tool_executor, stream_state)
  end

  defp completed_final_agent_message(payload, stream_state) do
    final_agent_message(payload) ||
      if(scoped_turn_message?(payload) and not stream_state.last_agent_message_scoped,
        do: nil,
        else: stream_state.last_agent_message
      )
  end

  defp handle_completed_turn(port, on_message, payload, payload_string, stream_state) do
    case completed_turn_result(payload, stream_state) do
      {:ok, final_agent_message} ->
        emit_turn_event(on_message, :turn_completed, payload, payload_string, port, payload)
        {:ok, payload, final_agent_message}

      {:error, event, reason} ->
        emit_turn_event(
          on_message,
          event,
          payload,
          payload_string,
          port,
          Map.get(payload, "params")
        )

        {:error, reason}
    end
  end

  defp completed_turn_result(payload, stream_state) do
    params = Map.get(payload, "params")

    case get_in(payload, ["params", "turn", "status"]) do
      nil ->
        {:ok, completed_final_agent_message(payload, stream_state)}

      "completed" ->
        {:ok, completed_final_agent_message(payload, stream_state)}

      "failed" ->
        {:error, :turn_failed, {:turn_failed, params}}

      "interrupted" ->
        {:error, :turn_cancelled, {:turn_cancelled, params}}

      status ->
        {:error, :turn_failed, {:unexpected_turn_status, status, params}}
    end
  end

  defp maybe_handle_approval_request(
         port,
         "item/commandExecution/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_policy
       ) do
    approve_command_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_policy
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/call",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         tool_executor,
         _auto_approve_requests
       ) do
    tool_name = tool_call_name(params)
    arguments = tool_call_arguments(params)

    result =
      tool_name
      |> tool_executor.(arguments)
      |> normalize_dynamic_tool_result()

    send_message(port, %{
      "id" => id,
      "result" => result
    })

    event =
      case result do
        %{"success" => true} -> :tool_call_completed
        _ when is_nil(tool_name) -> :unsupported_tool_call
        _ -> :tool_call_failed
      end

    emit_message(on_message, event, %{payload: payload, raw: payload_string}, metadata)

    :approved
  end

  defp maybe_handle_approval_request(
         port,
         "execCommandApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_policy
       ) do
    approve_command_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_policy
    )
  end

  defp maybe_handle_approval_request(
         port,
         "applyPatchApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_policy
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_all?(auto_approve_policy)
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/fileChange/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_policy
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_all?(auto_approve_policy)
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/requestUserInput",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         on_message,
         metadata,
         _tool_executor,
         auto_approve_policy
       ) do
    maybe_auto_answer_tool_request_user_input(
      port,
      id,
      params,
      payload,
      payload_string,
      on_message,
      metadata,
      auto_approve_all?(auto_approve_policy)
    )
  end

  defp maybe_handle_approval_request(
         _port,
         _method,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         _tool_executor,
         _auto_approve_requests
       ) do
    :unhandled
  end

  defp normalize_dynamic_tool_result(%{"success" => success} = result) when is_boolean(success) do
    output =
      case Map.get(result, "output") do
        existing_output when is_binary(existing_output) -> existing_output
        _ -> dynamic_tool_output(result)
      end

    content_items =
      case Map.get(result, "contentItems") do
        existing_items when is_list(existing_items) -> existing_items
        _ -> dynamic_tool_content_items(output)
      end

    result
    |> Map.put("output", output)
    |> Map.put("contentItems", content_items)
  end

  defp normalize_dynamic_tool_result(result) do
    %{
      "success" => false,
      "output" => inspect(result),
      "contentItems" => dynamic_tool_content_items(inspect(result))
    }
  end

  defp dynamic_tool_output(%{"contentItems" => [%{"text" => text} | _]}) when is_binary(text),
    do: text

  defp dynamic_tool_output(result), do: Jason.encode!(result, pretty: true)

  defp dynamic_tool_content_items(output) when is_binary(output) do
    [
      %{
        "type" => "inputText",
        "text" => output
      }
    ]
  end

  defp approve_command_or_require(
         port,
         id,
         decision,
         payload,
         payload_string,
         on_message,
         metadata,
         auto_approve_policy
       ) do
    if auto_approve_all?(auto_approve_policy) or
         auto_approve_command?(payload, auto_approve_policy) do
      approve_or_require(port, id, decision, payload, payload_string, on_message, metadata, true)
    else
      approve_or_require(port, id, decision, payload, payload_string, on_message, metadata, false)
    end
  end

  defp auto_approve_all?(%{all: true}), do: true
  defp auto_approve_all?(_auto_approve_policy), do: false

  defp auto_approve_command?(payload, %{command_patterns: patterns}) when is_list(patterns) do
    case approval_command(payload) do
      command when is_binary(command) ->
        Enum.any?(patterns, fn pattern ->
          is_binary(pattern) and pattern != "" and String.contains?(command, pattern)
        end)

      _ ->
        false
    end
  end

  defp auto_approve_command?(_payload, _auto_approve_policy), do: false

  defp approval_command(payload) do
    payload
    |> map_path(["params", "parsedCmd"])
    |> fallback_command(payload)
    |> normalize_command()
  end

  defp fallback_command(nil, payload) do
    map_path(payload, ["params", "command"]) ||
      map_path(payload, ["params", "cmd"]) ||
      map_path(payload, ["params", "argv"]) ||
      map_path(payload, ["params", "args"])
  end

  defp fallback_command(command, _payload), do: command

  defp normalize_command(%{} = command) do
    binary_command =
      map_value(command, ["parsedCmd", :parsedCmd, "command", :command, "cmd", :cmd])

    args = map_value(command, ["args", :args, "argv", :argv])

    if is_binary(binary_command) and is_list(args) do
      normalize_command([binary_command | args])
    else
      normalize_command(binary_command || args)
    end
  end

  defp normalize_command(command) when is_binary(command), do: command

  defp normalize_command(command) when is_list(command) do
    if Enum.all?(command, &is_binary/1), do: Enum.join(command, " "), else: nil
  end

  defp normalize_command(_command), do: nil

  defp map_path(map, path) when is_map(map) and is_list(path) do
    Enum.reduce_while(path, map, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp map_path(_map, _path), do: nil

  defp map_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp map_value(_map, _keys), do: nil

  defp approve_or_require(
         port,
         id,
         decision,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    send_message(port, %{"id" => id, "result" => %{"decision" => decision}})

    emit_message(
      on_message,
      :approval_auto_approved,
      %{payload: payload, raw: payload_string, decision: decision},
      metadata
    )

    :approved
  end

  defp approve_or_require(
         _port,
         _id,
         _decision,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         false
       ) do
    :approval_required
  end

  defp maybe_auto_answer_tool_request_user_input(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    case tool_request_user_input_approval_answers(params) do
      {:ok, answers, decision} ->
        send_message(port, %{"id" => id, "result" => %{"answers" => answers}})

        emit_message(
          on_message,
          :approval_auto_approved,
          %{payload: payload, raw: payload_string, decision: decision},
          metadata
        )

        :approved

      :error ->
        reply_with_non_interactive_tool_input_answer(
          port,
          id,
          params,
          payload,
          payload_string,
          on_message,
          metadata
        )
    end
  end

  defp maybe_auto_answer_tool_request_user_input(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata,
         false
       ) do
    reply_with_non_interactive_tool_input_answer(
      port,
      id,
      params,
      payload,
      payload_string,
      on_message,
      metadata
    )
  end

  defp tool_request_user_input_approval_answers(%{"questions" => questions})
       when is_list(questions) do
    answers =
      Enum.reduce_while(questions, %{}, fn question, acc ->
        case tool_request_user_input_approval_answer(question) do
          {:ok, question_id, answer_label} ->
            {:cont, Map.put(acc, question_id, %{"answers" => [answer_label]})}

          :error ->
            {:halt, :error}
        end
      end)

    case answers do
      :error -> :error
      answer_map when map_size(answer_map) > 0 -> {:ok, answer_map, "Approve this Session"}
      _ -> :error
    end
  end

  defp tool_request_user_input_approval_answers(_params), do: :error

  defp reply_with_non_interactive_tool_input_answer(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata
       ) do
    case tool_request_user_input_unavailable_answers(params) do
      {:ok, answers} ->
        send_message(port, %{"id" => id, "result" => %{"answers" => answers}})

        emit_message(
          on_message,
          :tool_input_auto_answered,
          %{payload: payload, raw: payload_string, answer: @non_interactive_tool_input_answer},
          metadata
        )

        :approved

      :error ->
        :input_required
    end
  end

  defp tool_request_user_input_unavailable_answers(%{"questions" => questions})
       when is_list(questions) do
    answers =
      Enum.reduce_while(questions, %{}, fn question, acc ->
        case tool_request_user_input_question_id(question) do
          {:ok, question_id} ->
            {:cont, Map.put(acc, question_id, %{"answers" => [@non_interactive_tool_input_answer]})}

          :error ->
            {:halt, :error}
        end
      end)

    case answers do
      :error -> :error
      answer_map when map_size(answer_map) > 0 -> {:ok, answer_map}
      _ -> :error
    end
  end

  defp tool_request_user_input_unavailable_answers(_params), do: :error

  defp tool_request_user_input_question_id(%{"id" => question_id}) when is_binary(question_id),
    do: {:ok, question_id}

  defp tool_request_user_input_question_id(_question), do: :error

  defp tool_request_user_input_approval_answer(%{"id" => question_id, "options" => options})
       when is_binary(question_id) and is_list(options) do
    case tool_request_user_input_approval_option_label(options) do
      nil -> :error
      answer_label -> {:ok, question_id, answer_label}
    end
  end

  defp tool_request_user_input_approval_answer(_question), do: :error

  defp tool_request_user_input_approval_option_label(options) do
    options
    |> Enum.map(&tool_request_user_input_option_label/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      labels ->
        Enum.find(labels, &(&1 == "Approve this Session")) ||
          Enum.find(labels, &(&1 == "Approve Once")) ||
          Enum.find(labels, &approval_option_label?/1)
    end
  end

  defp tool_request_user_input_option_label(%{"label" => label}) when is_binary(label), do: label
  defp tool_request_user_input_option_label(_option), do: nil

  defp approval_option_label?(label) when is_binary(label) do
    normalized_label =
      label
      |> String.trim()
      |> String.downcase()

    String.starts_with?(normalized_label, "approve") or
      String.starts_with?(normalized_label, "allow")
  end

  defp await_response(port, request_id) do
    with_timeout_response(port, request_id, Config.settings!().codex.read_timeout_ms, "")
  end

  defp with_timeout_response(port, request_id, timeout_ms, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_response(port, request_id, complete_line, timeout_ms)

      {^port, {:data, {:noeol, chunk}}} ->
        with_timeout_response(port, request_id, timeout_ms, pending_line <> to_string(chunk))

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :response_timeout}
    end
  end

  defp handle_response(port, request_id, data, timeout_ms) do
    payload = to_string(data)

    case Jason.decode(payload) do
      {:ok, %{"id" => ^request_id, "error" => error}} ->
        {:error, {:response_error, error}}

      {:ok, %{"id" => ^request_id, "result" => result}} ->
        {:ok, result}

      {:ok, %{"id" => ^request_id} = response_payload} ->
        {:error, {:response_error, response_payload}}

      {:ok, %{} = other} ->
        Logger.debug("Ignoring message while waiting for response: #{inspect(other)}")
        with_timeout_response(port, request_id, timeout_ms, "")

      {:error, _} ->
        log_non_json_stream_line(payload, "response stream")
        with_timeout_response(port, request_id, timeout_ms, "")
    end
  end

  defp log_non_json_stream_line(data, stream_label) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Codex #{stream_label} output: #{text}")
      else
        Logger.debug("Codex #{stream_label} output: #{text}")
      end
    end
  end

  defp protocol_message_candidate?(data) do
    data
    |> to_string()
    |> String.trim_leading()
    |> String.starts_with?("{")
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError ->
            :ok
        end
    end
  end

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message =
      metadata
      |> Map.merge(details)
      |> Map.put(:event, event)
      |> Map.put(:timestamp, DateTime.utc_now())

    on_message.(message)
  end

  defp metadata_from_message(port, payload) do
    port |> port_metadata(nil) |> maybe_set_usage(payload)
  end

  defp maybe_set_usage(metadata, payload) when is_map(payload) do
    usage = Map.get(payload, "usage") || Map.get(payload, :usage)

    if is_map(usage) do
      Map.put(metadata, :usage, usage)
    else
      metadata
    end
  end

  defp maybe_set_usage(metadata, _payload), do: metadata

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp default_on_message(_message), do: :ok

  defp tool_call_name(params) when is_map(params) do
    case Map.get(params, "tool") || Map.get(params, :tool) || Map.get(params, "name") ||
           Map.get(params, :name) do
      name when is_binary(name) ->
        case String.trim(name) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp tool_call_name(_params), do: nil

  defp tool_call_arguments(params) when is_map(params) do
    Map.get(params, "arguments") || Map.get(params, :arguments) || %{}
  end

  defp tool_call_arguments(_params), do: %{}

  defp send_message(port, message) do
    line = Jason.encode!(message) <> "\n"
    Port.command(port, line)
  end

  defp needs_input?("mcpServer/elicitation/request", payload) when is_map(payload), do: true

  defp needs_input?(method, payload)
       when is_binary(method) and is_map(payload) do
    String.starts_with?(method, "turn/") && input_required_method?(method, payload)
  end

  defp needs_input?(_method, _payload), do: false

  defp input_required_method?(method, payload) when is_binary(method) do
    method in [
      "turn/input_required",
      "turn/needs_input",
      "turn/need_input",
      "turn/request_input",
      "turn/request_response",
      "turn/provide_input",
      "turn/approval_required"
    ] || request_payload_requires_input?(payload)
  end

  defp request_payload_requires_input?(payload) do
    params = Map.get(payload, "params")
    needs_input_field?(payload) || needs_input_field?(params)
  end

  defp needs_input_field?(payload) when is_map(payload) do
    Map.get(payload, "requiresInput") == true or
      Map.get(payload, "needsInput") == true or
      Map.get(payload, "input_required") == true or
      Map.get(payload, "inputRequired") == true or
      Map.get(payload, "type") == "input_required" or
      Map.get(payload, "type") == "needs_input"
  end

  defp needs_input_field?(_payload), do: false
end

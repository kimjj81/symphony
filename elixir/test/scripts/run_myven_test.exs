defmodule SymphonyElixir.RunMyvenScriptTest do
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/run_myven.sh", __DIR__)

  test "starts Symphony while fixed webhook registration keeps failing" do
    fixture = build_fixture(999, 0.4)

    {output, status} = run_script(fixture, "30")

    assert status == 0, output
    assert File.exists?(fixture.started_file)
    assert output =~ "GitHub API 장애 감지(HTTP 503)"
    assert output =~ "Symphony는 계속 실행 중"
    assert String.contains?(File.read!(fixture.registration_log), "HTTP 503")
    assert String.contains?(File.read!(fixture.registration_log), "30초 후 재시도")
  end

  test "retries fixed webhook registration until GitHub recovers" do
    fixture = build_fixture(3, 0.6)

    {output, status} = run_script(fixture, "0.05")

    assert status == 0, output
    assert File.read!(fixture.gh_count_file) == "3\n"
    assert output =~ "GitHub webhook 등록 복구 완료 (실패 2회 후)"
    assert String.contains?(File.read!(fixture.registration_log), "Created GitHub webhook 614264742")
  end

  defp build_fixture(succeed_after, symphony_lifetime_seconds) do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-run-myven-test-#{System.unique_integer([:positive, :monotonic])}"
      )

    bin_dir = Path.join(root, "bin")
    File.mkdir_p!(bin_dir)
    on_exit(fn -> File.rm_rf!(root) end)

    started_file = Path.join(root, "symphony-started")
    gh_count_file = Path.join(root, "gh-count")
    registration_log = Path.join(root, "webhook-registration.log")

    write_executable!(Path.join(bin_dir, "mise"), """
    #!/usr/bin/env bash
    set -euo pipefail

    case "${1:-}" in
      trust|install)
        exit 0
        ;;
      exec)
        shift
        if [ "${1:-}" = "--" ]; then shift; fi
        if [ "${1:-}" = "mix" ]; then exit 0; fi
        printf 'started\n' > "$SYMPHONY_TEST_STARTED_FILE"
        sleep "$SYMPHONY_TEST_LIFETIME_SECONDS"
        exit 0
        ;;
    esac

    exit 0
    """)

    write_executable!(Path.join(bin_dir, "gh"), """
    #!/usr/bin/env bash
    set -euo pipefail

    count=0
    if [ -f "$SYMPHONY_TEST_GH_COUNT_FILE" ]; then
      count="$(tr -d '\n' < "$SYMPHONY_TEST_GH_COUNT_FILE")"
    fi
    count=$((count + 1))
    printf '%s\n' "$count" > "$SYMPHONY_TEST_GH_COUNT_FILE"

    if [ "$count" -ge "$SYMPHONY_TEST_GH_SUCCEED_AFTER" ]; then
      printf '614264742\n'
      exit 0
    fi

    printf 'gh: HTTP 503\n' >&2
    exit 1
    """)

    %{
      bin_dir: bin_dir,
      root: root,
      started_file: started_file,
      gh_count_file: gh_count_file,
      registration_log: registration_log,
      succeed_after: succeed_after,
      symphony_lifetime_seconds: symphony_lifetime_seconds
    }
  end

  defp run_script(fixture, retry_seconds) do
    env = [
      {"PATH", fixture.bin_dir <> ":" <> System.get_env("PATH")},
      {"HOME", fixture.root},
      {"SYMPHONY_GITHUB_WEBHOOK_MODE", "fixed"},
      {"SYMPHONY_GITHUB_WEBHOOK_SECRET", "test-secret"},
      {"SYMPHONY_GITHUB_WEBHOOK_URL", "https://example.test/github"},
      {"SYMPHONY_GITHUB_WEBHOOK_ID_FILE", Path.join(fixture.root, "hook-id")},
      {"SYMPHONY_GITHUB_WEBHOOK_REGISTRATION_LOG", fixture.registration_log},
      {"SYMPHONY_GITHUB_WEBHOOK_RETRY_SECONDS", retry_seconds},
      {"SYMPHONY_PORT", "58400"},
      {"SYMPHONY_TEST_GH_COUNT_FILE", fixture.gh_count_file},
      {"SYMPHONY_TEST_GH_SUCCEED_AFTER", Integer.to_string(fixture.succeed_after)},
      {"SYMPHONY_TEST_STARTED_FILE", fixture.started_file},
      {"SYMPHONY_TEST_LIFETIME_SECONDS", Float.to_string(fixture.symphony_lifetime_seconds)}
    ]

    System.cmd("bash", [@script],
      cd: fixture.root,
      env: env,
      stderr_to_stdout: true
    )
  end

  defp write_executable!(path, contents) do
    File.write!(path, contents)
    File.chmod!(path, 0o755)
  end
end

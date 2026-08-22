#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <ssh-target> [remote-database-path]" >&2
  exit 2
fi

ssh_target=$1
remote_database_path=${2:-'${HOME}/.local/share/aura/aura.db'}
if [[ ! ${remote_database_path} =~ ^[/A-Za-z0-9._$}{-]+$ ]]; then
  echo "Remote database path contains unsupported characters" >&2
  exit 2
fi
proof_directory=$(mktemp -d /tmp/aura-phase0-proof.XXXXXX)
proof_database="${proof_directory}/aura-redacted.db"

cleanup() {
  if [[ -d "${proof_directory}" ]]; then
    if command -v trash >/dev/null 2>&1; then
      trash "${proof_directory}"
    else
      rm -r -- "${proof_directory}"
    fi
  fi
  if [[ -f erl_crash.dump ]]; then
    if command -v trash >/dev/null 2>&1; then
      trash erl_crash.dump
    else
      rm -- erl_crash.dump
    fi
  fi
}
trap cleanup EXIT

ssh "${ssh_target}" \
  "sqlite3 -readonly \"${remote_database_path}\" '.dump'" \
  | sqlite3 "${proof_database}"

# Redact content before the first query. Keep only values that the migration
# needs to preserve row relationships and state semantics.
sqlite3 "${proof_database}" <<'SQL'
UPDATE conversations
SET platform_id='redacted-'||rowid,
    parent_id=CASE WHEN parent_id IS NULL THEN NULL ELSE 'redacted-parent-'||rowid END,
    compaction_summary=CASE WHEN compaction_summary IS NULL THEN NULL ELSE '[redacted]' END;
UPDATE messages
SET content='[redacted]',
    author_id=CASE WHEN author_id IS NULL THEN NULL ELSE 'redacted' END,
    author_name=CASE WHEN author_name IS NULL THEN NULL ELSE 'redacted' END,
    tool_call_id=CASE WHEN tool_call_id IS NULL THEN NULL ELSE 'redacted' END,
    tool_calls=CASE WHEN tool_calls IS NULL THEN NULL ELSE '[]' END,
    tool_name=CASE WHEN tool_name IS NULL THEN NULL ELSE 'redacted' END;
UPDATE events
SET external_id='redacted-'||rowid,
    subject='[redacted]',
    data_json='{}',
    tags_json='[]';
UPDATE flares
SET label='redacted-'||rowid,
    thread_id=CASE WHEN thread_id IS NULL THEN NULL ELSE 'redacted-thread-'||rowid END,
    original_prompt='[redacted]',
    execution='{}',
    triggers='[]',
    tools='[]',
    workspace='',
    session_id='',
    result_text=CASE WHEN result_text IS NULL THEN NULL ELSE '[redacted]' END;
UPDATE external_asks
SET id='redacted-'||rowid,
    source='redacted',
    channel_id='redacted',
    message_id='redacted',
    text='[redacted]',
    buttons_json='[]',
    decision=CASE WHEN decision IS NULL THEN NULL ELSE '[redacted]' END;
VACUUM;
SQL

report_before() {
  sqlite3 "${proof_database}" \
    "SELECT 'schema='||(SELECT version FROM schema_version)||' events='||(SELECT count(*) FROM events)||' flares='||(SELECT count(*) FROM flares)||' conversations='||(SELECT count(*) FROM conversations)||' messages='||(SELECT count(*) FROM messages);"
}

report_after() {
  sqlite3 "${proof_database}" \
    "SELECT 'schema='||(SELECT version FROM schema_version)||' events='||(SELECT count(*) FROM events)||' flares='||(SELECT count(*) FROM flares)||' conversations='||(SELECT count(*) FROM conversations)||' messages='||(SELECT count(*) FROM messages)||' attempts='||(SELECT count(*) FROM flare_attempts)||' backfill_events='||(SELECT count(*) FROM flare_events WHERE event_type='attempt_backfilled')||' orphan_attempts='||(SELECT count(*) FROM flare_attempts a LEFT JOIN flares f ON f.id=a.flare_id WHERE f.id IS NULL)||' invalid_archived='||(SELECT count(*) FROM flare_attempts a JOIN flares f ON f.id=a.flare_id WHERE f.status='archived' AND (a.status!='completed' OR a.ended_at_ms=0))||' integrity='||(SELECT integrity_check FROM pragma_integrity_check);"
}

run_startup() {
  AURA_PROOF_DB="${proof_database}" nix develop --command erl -noshell \
    -pa build/dev/erlang/*/ebin \
    -eval 'Path=list_to_binary(os:getenv("AURA_PROOF_DB")), {ok,Db}='\''aura@db'\'':start(Path), {ok,_}='\''aura@acp@flare_manager'\'':start(1, <<"synthetic">>, fun(_)->nil end, tmux, Db), timer:sleep(1500), halt().'
}

printf 'BEFORE %s\n' "$(report_before)"
run_startup
printf 'AFTER1 %s\n' "$(report_after)"
run_startup
printf 'AFTER2 %s\n' "$(report_after)"

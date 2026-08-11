#!/usr/bin/env bash

# Shared, side-effect-free validation used by the local and release packaging
# entry points. Callers intentionally retain their own `set` options.

TASKSCOPE_DEVELOPMENT_BUNDLE_ID="com.local.TaskScope"

taskscope_validate_bundle_id() {
  local bundle_id="$1"

  if [[ ${#bundle_id} -gt 255 \
    || ! "$bundle_id" =~ ^[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z][A-Za-z0-9-]*)+$ ]]; then
    echo "Invalid TaskScope bundle identifier: '$bundle_id'." >&2
    echo "Use a reverse-DNS identifier containing letters, numbers, and hyphens." >&2
    return 1
  fi
}

taskscope_resolve_bundle_id() {
  local bundle_id="${TASKSCOPE_BUNDLE_ID:-$TASKSCOPE_DEVELOPMENT_BUNDLE_ID}"

  taskscope_validate_bundle_id "$bundle_id" || return 1
  printf '%s' "$bundle_id"
}

taskscope_read_release_value() {
  local path="$1"
  local label="$2"
  local value

  if [[ ! -f "$path" ]]; then
    echo "Missing $label source: $path" >&2
    return 1
  fi

  value="$(tr -d '[:space:]' < "$path")"
  if [[ -z "$value" ]]; then
    echo "$label source is empty: $path" >&2
    return 1
  fi

  printf '%s' "$value"
}

taskscope_process_command() {
  local pid="$1"
  local command

  command="$(/bin/ps -ww -p "$pid" -o command= 2>/dev/null)" || return 1
  [[ -n "$command" ]] || return 1
  printf '%s' "$command"
}

taskscope_process_identity() {
  local pid="$1"
  local identity

  # PID alone is unsafe because macOS can reuse it after a process exits. The
  # process start time and full command together provide a stable shell-level
  # identity that can be revalidated immediately before each signal.
  identity="$(/bin/ps -ww -p "$pid" -o lstart= -o command= 2>/dev/null)" || return 1
  [[ -n "$identity" ]] || return 1
  printf '%s' "$identity"
}

taskscope_wait_for_process_identity() {
  local pid="$1"
  local attempts="${2:-20}"
  local identity
  local attempt

  for ((attempt = 1; attempt <= attempts; attempt += 1)); do
    if identity="$(taskscope_process_identity "$pid")"; then
      printf '%s' "$identity"
      return 0
    fi
    /bin/sleep 0.05
  done

  return 1
}

taskscope_process_matches_identity() {
  local pid="$1"
  local expected_identity="$2"
  local current_identity

  current_identity="$(taskscope_process_identity "$pid")" || return 1
  [[ "$current_identity" == "$expected_identity" ]]
}

taskscope_canonical_file_path() {
  local path="$1"
  local directory

  [[ -e "$path" ]] || return 1
  directory="$(cd "$(dirname "$path")" && pwd -P)" || return 1
  printf '%s/%s' "$directory" "$(basename "$path")"
}

taskscope_process_executable_path() {
  local pid="$1"
  local executable

  # `lsof` obtains the process text vnode from the kernel. Unlike `ps`
  # command/argv0, an untrusted process cannot forge this path with `exec -a`.
  executable="$(
    /usr/sbin/lsof -a -p "$pid" -d txt -Fn 2>/dev/null \
      | /usr/bin/awk 'substr($0, 1, 1) == "n" { print substr($0, 2); exit }'
  )"
  [[ -n "$executable" ]] || return 1
  printf '%s' "$executable"
}

taskscope_process_matches_executable() {
  local pid="$1"
  local expected_executable="$2"
  local expected_canonical
  local actual_executable
  local actual_canonical

  expected_canonical="$(taskscope_canonical_file_path "$expected_executable")" || return 1
  actual_executable="$(taskscope_process_executable_path "$pid")" || return 1
  actual_canonical="$(taskscope_canonical_file_path "$actual_executable")" || return 1
  [[ "$actual_canonical" == "$expected_canonical" ]]
}

taskscope_send_signal() {
  local signal="$1"
  local pid="$2"

  /bin/kill "-$signal" "$pid"
}

taskscope_list_processes() {
  /bin/ps -ww -axo pid=,command=
}

taskscope_pause() {
  /bin/sleep "$1"
}

taskscope_signal_process_if_identity_matches() {
  local signal="$1"
  local pid="$2"
  local expected_identity="$3"
  local expected_executable="$4"

  case "$signal" in
    TERM|KILL)
      ;;
    *)
      echo "Unsupported TaskScope packaging signal: $signal" >&2
      return 2
      ;;
  esac

  taskscope_process_matches_identity "$pid" "$expected_identity" || return 1
  taskscope_process_matches_executable "$pid" "$expected_executable" || return 1
  taskscope_send_signal "$signal" "$pid"
}

taskscope_stop_processes_for_executable() {
  local executable="$1"
  local canonical_executable
  local pid
  local command
  local identity
  local current_command
  local index
  local -a matching_pids=()
  local -a matching_identities=()

  [[ -x "$executable" ]] || return 0
  canonical_executable="$(taskscope_canonical_file_path "$executable")" || return 0

  while read -r pid command; do
    if [[ "$command" == "$executable" || "$command" == "$executable "* \
      || "$command" == "$canonical_executable" || "$command" == "$canonical_executable "* ]]; then
      identity="$(taskscope_process_identity "$pid")" || continue
      current_command="$(taskscope_process_command "$pid")" || continue
      if [[ "$current_command" == "$executable" || "$current_command" == "$executable "* \
        || "$current_command" == "$canonical_executable" \
        || "$current_command" == "$canonical_executable "* ]] \
        && taskscope_process_matches_identity "$pid" "$identity" \
        && taskscope_process_matches_executable "$pid" "$canonical_executable"; then
        matching_pids+=("$pid")
        matching_identities+=("$identity")
      fi
    fi
  done < <(taskscope_list_processes)

  if [[ "${#matching_pids[@]}" -eq 0 ]]; then
    return 0
  fi

  for ((index = 0; index < ${#matching_pids[@]}; index++)); do
    taskscope_signal_process_if_identity_matches \
      TERM "${matching_pids[$index]}" "${matching_identities[$index]}" \
      "$canonical_executable" >/dev/null 2>&1 || true
  done

  for _ in {1..20}; do
    local any_running=0
    for ((index = 0; index < ${#matching_pids[@]}; index++)); do
      if taskscope_process_matches_identity \
        "${matching_pids[$index]}" "${matching_identities[$index]}"; then
        any_running=1
        break
      fi
    done
    [[ "$any_running" -eq 0 ]] && return 0
    taskscope_pause 0.1
  done

  for ((index = 0; index < ${#matching_pids[@]}; index++)); do
    taskscope_signal_process_if_identity_matches \
      KILL "${matching_pids[$index]}" "${matching_identities[$index]}" \
      "$canonical_executable" >/dev/null 2>&1 || true
  done

  for _ in {1..20}; do
    local any_running=0
    for ((index = 0; index < ${#matching_pids[@]}; index++)); do
      if taskscope_process_matches_identity \
        "${matching_pids[$index]}" "${matching_identities[$index]}"; then
        any_running=1
        break
      fi
    done
    [[ "$any_running" -eq 0 ]] && return 0
    taskscope_pause 0.1
  done

  echo "Could not stop every verified TaskScope process for $canonical_executable." >&2
  return 1
}

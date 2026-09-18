//! C-ABI wrapper over `lumio_tools` (preferred tools only, no source blocks).

use lumio_engine::config::RuntimeConfig;
use lumio_tools::{Action, Launch, Resolved, Target};
use std::os::raw::c_char;

use crate::state::{cstr_to_string, json_cstring_or_null};

pub(crate) fn lumio_tool_action_json_impl(
    action: *const c_char,
    _candidate_id: *const c_char,
    _row_title: *const c_char,
    path: *const c_char,
    is_dir: bool,
    _ancestors_json: *const c_char,
) -> *mut c_char {
    let resolved = resolve(action, path, is_dir).map(|outcome| Resolved::from(outcome));
    json_cstring_or_null(resolved.as_ref().and_then(json))
}

pub(crate) fn lumio_perform_tool_action_json_impl(
    action: *const c_char,
    _candidate_id: *const c_char,
    _row_title: *const c_char,
    path: *const c_char,
    is_dir: bool,
    _ancestors_json: *const c_char,
) -> *mut c_char {
    let resolved = resolve(action, path, is_dir).map(|outcome| match outcome {
        Ok(Launch::Shell { tool, command }) => performed(&tool, command),
        other => Resolved::from(other),
    });
    json_cstring_or_null(resolved.as_ref().and_then(json))
}

fn resolve(
    action: *const c_char,
    path: *const c_char,
    is_dir: bool,
) -> Option<Result<Launch, lumio_tools::Unavailable>> {
    let action = Action::from_id(&cstr_to_string(action))?;
    let path = cstr_to_string(path);
    if path.is_empty() {
        return None;
    }
    let target = if is_dir {
        Target::Folder(path)
    } else {
        Target::File(path)
    };
    Some(action.resolve(&RuntimeConfig::tools_cached(), &target))
}

fn json(resolved: &Resolved) -> Option<String> {
    serde_json::to_string(resolved).ok()
}

fn performed(tool: &str, command: String) -> Resolved {
    let ok = std::process::Command::new("/bin/sh")
        .arg("-lc")
        .arg(&command)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .is_ok();
    if ok {
        Resolved::performed(Some(tool.to_string()))
    } else {
        Resolved::failed(Some(tool.to_string()), "failed to spawn command".to_string())
    }
}

pub(crate) fn lumio_tool_actions_json_impl() -> *mut c_char {
    let ids: Vec<&str> = Action::ALL.iter().map(|action| action.id()).collect();
    json_cstring_or_null(serde_json::to_string(&ids).ok())
}

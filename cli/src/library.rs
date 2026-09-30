//! Create portable data libraries without a source checkout or developer tools.
use std::{env, fs, path::Path};
use anyhow::{Result, bail};
use crate::{Repo, inventory};

pub fn initialize(root: &Path) -> Result<()> {
    if root.exists() && (!root.is_dir() || fs::read_dir(root)?.next().is_some()) {
        bail!("Choose a new or empty folder; existing files will not be overwritten.");
    }
    fs::create_dir_all(root)?;
    for part in ["items", "inbox", "templates", ".agents/skills/process-inbox", ".vinted/bin"] {
        fs::create_dir_all(root.join(part))?;
    }
    fs::write(root.join("templates/listing.md"), include_str!("../../templates/listing.md"))?;
    fs::write(root.join("AGENTS.md"), include_str!("../../AGENTS.md"))?;
    fs::write(root.join(".agents/skills/process-inbox/SKILL.md"), include_str!("../../.agents/skills/process-inbox/SKILL.md"))?;
    fs::copy(env::current_exe()?, root.join(".vinted/bin/vinted"))?;
    if let Some(helper) = env::var_os("VINTED_IMAGE_CONVERTER") {
        fs::copy(helper, root.join(".vinted/bin/VintedPhotoConverter"))?;
    }
    fs::write(root.join("vinted"), r#"#!/bin/sh
set -eu
root="$(cd "$(dirname "$0")" && pwd)"
export VINTED_REPO="$root"
if [ -x "$root/.vinted/bin/VintedPhotoConverter" ]; then
    export VINTED_IMAGE_CONVERTER="${VINTED_IMAGE_CONVERTER:-$root/.vinted/bin/VintedPhotoConverter}"
fi
exec "${VINTED_CLI_BINARY:-$root/.vinted/bin/vinted}" "$@"
"#)?;
    #[cfg(unix)] {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(root.join("vinted"), fs::Permissions::from_mode(0o755))?;
    }
    fs::write(root.join(".gitignore"), "originals/\n.cache/\n.DS_Store\n.vinted/\n")?;
    inventory::write(&Repo { root: fs::canonicalize(root)? })?;
    println!("Created library at {}", root.display());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn creates_library_and_refuses_existing_data() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("Selling library");
        initialize(&root).unwrap();
        for part in ["items", "inbox", "templates/listing.md", "AGENTS.md", ".agents/skills/process-inbox/SKILL.md", "vinted", ".vinted/bin/vinted", "INVENTORY.md"] {
            assert!(root.join(part).exists(), "missing {part}");
        }
        fs::write(root.join("items/keep.txt"), "keep").unwrap();
        assert!(initialize(&root).is_err());
        assert_eq!(fs::read_to_string(root.join("items/keep.txt")).unwrap(), "keep");
    }
}

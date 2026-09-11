//! Keep an update from replacing the identity to which macOS granted access.
use std::{
    io::Cursor,
    path::{Component, Path},
    process::Command,
};

const IDENTIFIER: &str = "dev.prism.desktop";
const SIGNATURE_ERROR: &str = "This update changes Prism's signing identity and would reset macOS permissions. The installed app was not changed.";

fn requirement_from(details: &str, requirement: &str) -> Result<String, String> {
    if !details
        .lines()
        .any(|line| line == format!("Identifier={IDENTIFIER}"))
        || details.contains("Signature=adhoc")
        || !details.lines().any(|line| line.starts_with("Authority="))
    {
        return Err(SIGNATURE_ERROR.into());
    }
    let requirement = requirement
        .lines()
        .find_map(|line| line.trim_start_matches("# ").strip_prefix("designated => "))
        .ok_or(SIGNATURE_ERROR)?;
    if requirement.contains("cdhash")
        || !requirement.contains(&format!("identifier \"{IDENTIFIER}\""))
    {
        return Err(SIGNATURE_ERROR.into());
    }
    Ok(requirement.into())
}

fn signature(bundle: &Path) -> Result<String, String> {
    let run = |args: &[&str]| -> Result<String, String> {
        let output = Command::new("/usr/bin/codesign")
            .args(args)
            .arg(bundle)
            .output()
            .map_err(|_| SIGNATURE_ERROR)?;
        if !output.status.success() {
            return Err(SIGNATURE_ERROR.into());
        }
        Ok(format!(
            "{}\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ))
    };
    run(&["--verify", "--deep", "--strict", "--all-architectures"])?;
    requirement_from(&run(&["-dv", "--verbose=4"])?, &run(&["-dr", "-"])?)
}

fn matches_requirement(bundle: &Path, requirement: &str) -> Result<(), String> {
    // A leading '=' denotes requirement source; otherwise codesign expects a file.
    let source = format!("={requirement}");
    let output = Command::new("/usr/bin/codesign")
        .args(["--verify", "--strict", "--all-architectures", "-R", &source])
        .arg(bundle)
        .output()
        .map_err(|_| SIGNATURE_ERROR)?;
    if output.status.success() {
        Ok(())
    } else {
        Err(SIGNATURE_ERROR.into())
    }
}

fn unpack(bytes: &[u8], root: &Path) -> Result<(), String> {
    let mut archive = tar::Archive::new(flate2::read::GzDecoder::new(Cursor::new(bytes)));
    let mut total = 0_u64;
    let mut entries = 0_u32;
    for entry in archive
        .entries()
        .map_err(|_| "Invalid app update archive.")?
    {
        let mut entry = entry.map_err(|_| "Invalid app update entry.")?;
        let path = entry.path().map_err(|_| "Invalid app update path.")?;
        let components: Vec<_> = path.components().collect();
        // Prism's bundle has regular files/directories only. Reject links and special
        // entries instead of allowing archive paths to escape the private staging dir.
        if components.first() != Some(&Component::Normal("Prism.app".as_ref()))
            || components
                .iter()
                .any(|part| !matches!(part, Component::Normal(_)))
            || !(entry.header().entry_type().is_file() || entry.header().entry_type().is_dir())
        {
            return Err("The update contains an unsupported app archive entry.".into());
        }
        total = total
            .checked_add(entry.size())
            .ok_or("The update is too large.")?;
        entries += 1;
        if total > 1024 * 1024 * 1024 || entries > 20_000 {
            return Err("The update is too large.".into());
        }
        if !entry
            .unpack_in(root)
            .map_err(|_| "Could not verify the app update archive.")?
        {
            return Err("The update contains an invalid app path.".into());
        }
    }
    Ok(())
}

pub fn verify(bytes: &[u8], installed: &Path) -> Result<(), String> {
    let previous = signature(installed)?;
    let staging = tempfile::Builder::new()
        .prefix("prism-update-check-")
        .tempdir()
        .map_err(|_| "Could not prepare app update verification.")?;
    unpack(bytes, staging.path())?;
    let candidate = staging.path().join("Prism.app");
    let next = signature(&candidate)?;
    matches_requirement(&candidate, &previous)?;
    matches_requirement(installed, &next)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[ignore = "Requires PRISM_SIGNED_TEST_APP pointing to a certificate-signed Prism bundle"]
    fn verifies_a_real_signed_app_archive_before_installing() {
        let installed = std::path::PathBuf::from(std::env::var("PRISM_SIGNED_TEST_APP").unwrap());
        if let Ok(path) = std::env::var("PRISM_UPDATE_ARCHIVE") {
            verify(&std::fs::read(path).unwrap(), &installed).unwrap();
            return;
        }
        let compressed = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
        let mut archive = tar::Builder::new(compressed);
        archive.append_dir_all("Prism.app", &installed).unwrap();
        let bytes = archive.into_inner().unwrap().finish().unwrap();
        verify(&bytes, &installed).unwrap();
    }

    #[test]
    fn requires_a_certificate_identity_for_the_same_app() {
        let details = "Identifier=dev.prism.desktop\nAuthority=Prism Local Signing\n";
        let dr =
            "designated => identifier \"dev.prism.desktop\" and certificate leaf = H\"012345\"";
        assert!(requirement_from(details, dr).is_ok());
        assert!(requirement_from(&format!("{details}Signature=adhoc\n"), dr).is_err());
        assert!(requirement_from(details, "designated => cdhash H\"012345\"").is_err());
        assert!(requirement_from(
            &details.replace("dev.prism.desktop", "dev.prism.desktop.test"),
            dr
        )
        .is_err());
    }

    #[test]
    fn rejects_archive_links_and_unexpected_roots() {
        for (path, kind) in [
            ("Other.app/file", tar::EntryType::Regular),
            ("Prism.app/link", tar::EntryType::Symlink),
        ] {
            let compressed =
                flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
            let mut archive = tar::Builder::new(compressed);
            let mut header = tar::Header::new_gnu();
            header.set_size(0);
            header.set_entry_type(kind);
            header.set_mode(0o644);
            if kind.is_symlink() {
                header.set_link_name("/tmp").unwrap();
            }
            header.set_cksum();
            archive
                .append_data(&mut header, path, std::io::empty())
                .unwrap();
            let bytes = archive.into_inner().unwrap().finish().unwrap();
            let root = tempfile::tempdir().unwrap();
            assert!(unpack(&bytes, root.path()).is_err());
        }
    }
}

#!/usr/bin/env python3
"""Publish what_to_test text as a build's TestFlight "What to Test" (beid#503).

Xcode Cloud gets this for free: it reads ``ios/TestFlight/WhatToTest.<locale>.txt``
next to the ``.xcodeproj`` and attaches the text itself (see
``ios/ci_scripts/ci_post_xcodebuild.sh`` and ``docs/xcode-cloud.md``). The
temporary GitHub Actions lane on ``emi`` uploads with
``xcodebuild -exportArchive`` instead, and that path has no such convention —
the notes have to be written through the App Store Connect API, which is what
this script does.

**No new runner dependency.** Authentication needs an ES256 JWT, and the only
piece of that Python's standard library cannot do is the signature, so the
signing is delegated to the ``openssl`` binary macOS already ships and the DER
signature it returns is converted here to the raw ``r || s`` form a JWT
requires. ``der_to_raw_signature`` is the one genuinely error-prone step and has
its own offline test.

Credentials come from the runner-local ``$ASC_CRED_DIR/env`` that the calling
script already sourced. Nothing here prints the token, the key, the key ID or
the issuer ID: a delivery log is not a private place.

Failure is fatal on purpose. This runs *after* a successful upload, so the
alternative is a green delivery whose testers see no notes at all — a silent
failure that looks exactly like success.
"""
import argparse
import base64
import json
import os
import plistlib
import subprocess
import sys
import time
import urllib.error
import urllib.request
import zipfile
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Sequence, Tuple

ASC_API_ROOT = "https://api.appstoreconnect.apple.com"
# Apple rejects a token whose lifetime exceeds 20 minutes for this audience.
TOKEN_LIFETIME_SECONDS = 15 * 60


class AscError(RuntimeError):
    """An App Store Connect request failed, or its answer was unusable."""


# --- JWT ---------------------------------------------------------------------


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def der_to_raw_signature(der: bytes, coordinate_size: int = 32) -> bytes:
    """Convert an OpenSSL ECDSA-Sig-Value (DER) into JWS raw ``r || s``.

    DER encodes r and s as signed integers of *minimal* length, so each is
    variable-width: a leading 0x00 appears when the high bit would otherwise
    read as negative, and leading zero bytes are dropped when they are not
    needed. JWS instead wants both fixed at the curve's coordinate size, so
    every value must be stripped and then left-padded. Getting this wrong
    produces a signature that is well-formed and simply never verifies.
    """
    if len(der) < 8 or der[0] != 0x30:
        raise ValueError("signature is not a DER SEQUENCE")

    # SEQUENCE length: short form (< 0x80) or long form (0x81 + one length byte).
    if der[1] & 0x80:
        length_bytes = der[1] & 0x7F
        if length_bytes != 1:
            raise ValueError("unsupported DER length encoding")
        offset = 3
    else:
        offset = 2

    def read_integer(pos: int) -> Tuple[bytes, int]:
        if der[pos] != 0x02:
            raise ValueError("expected a DER INTEGER in the signature")
        length = der[pos + 1]
        if length & 0x80:
            raise ValueError("unsupported DER INTEGER length encoding")
        start = pos + 2
        value = der[start : start + length]
        if len(value) != length:
            raise ValueError("truncated DER INTEGER in the signature")
        return value, start + length

    r_bytes, offset = read_integer(offset)
    s_bytes, offset = read_integer(offset)

    def normalize(value: bytes) -> bytes:
        value = value.lstrip(b"\x00")
        if len(value) > coordinate_size:
            raise ValueError("signature coordinate is wider than the curve")
        return value.rjust(coordinate_size, b"\x00")

    return normalize(r_bytes) + normalize(s_bytes)


def sign_es256(signing_input: bytes, key_path: Path) -> bytes:
    """Sign with the ASC .p8 through openssl, returning a raw r||s signature."""
    completed = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", str(key_path)],
        input=signing_input,
        capture_output=True,
        check=False,
    )
    if completed.returncode != 0:
        # openssl's stderr can name the key path but never its contents.
        raise AscError(
            "openssl refused to sign the App Store Connect token "
            f"(exit {completed.returncode}): {completed.stderr.decode('utf-8', 'replace').strip()}"
        )
    return der_to_raw_signature(completed.stdout)


def build_token(key_id: str, issuer_id: str, key_path: Path, now: Optional[int] = None) -> str:
    issued_at = int(time.time()) if now is None else now
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    payload = {
        "iss": issuer_id,
        "iat": issued_at,
        "exp": issued_at + TOKEN_LIFETIME_SECONDS,
        "aud": "appstoreconnect-v1",
    }
    signing_input = ".".join(
        b64url(json.dumps(part, separators=(",", ":"), sort_keys=True).encode("utf-8"))
        for part in (header, payload)
    ).encode("ascii")
    return signing_input.decode("ascii") + "." + b64url(sign_es256(signing_input, key_path))


# --- transport ---------------------------------------------------------------

# (method, url, body_or_None, token) -> decoded JSON, or None for 204.
Transport = Callable[[str, str, Optional[Dict[str, Any]], str], Optional[Dict[str, Any]]]


def urllib_transport(
    method: str, url: str, body: Optional[Dict[str, Any]], token: str
) -> Optional[Dict[str, Any]]:
    data = None if body is None else json.dumps(body).encode("utf-8")
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Authorization", f"Bearer {token}")
    if data is not None:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            raw = response.read()
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", "replace")
        # The URL and Apple's own error text are safe to print; the bearer
        # token lives only in the header and is never echoed here.
        raise AscError(f"{method} {url} failed with HTTP {error.code}: {detail}") from None
    except urllib.error.URLError as error:
        raise AscError(f"{method} {url} could not be reached: {error.reason}") from None
    if not raw:
        return None
    return json.loads(raw.decode("utf-8"))


# --- build discovery ---------------------------------------------------------


def _find_key(node: Any, key: str) -> Optional[str]:
    """Depth-first search for `key` in nested plist dicts/lists."""
    if isinstance(node, dict):
        value = node.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
        for child in node.values():
            found = _find_key(child, key)
            if found is not None:
                return found
    elif isinstance(node, list):
        for child in node:
            found = _find_key(child, key)
            if found is not None:
                return found
    return None


def discover_build_number(export_path: Path) -> Tuple[str, str]:
    """Return (build number, where it was read from) for the exported archive.

    The lane cannot compute this: ``manageAppVersionAndBuildNumber`` asks Apple
    to assign the build number during export, so it is only knowable from what
    the export produced. Two independent readings are tried, and both failing
    is fatal — attaching tester notes to a *guessed* build would write them onto
    somebody else's build, which is worse than not writing them at all. For the
    same reason there is deliberately no "most recent build" fallback.
    """
    if not export_path.is_dir():
        # Without this the listing below raises FileNotFoundError and the
        # operator gets a traceback instead of the sentence this function
        # exists to print. The job fails either way; only the diagnostic is
        # lost, which is the part that has to survive a 3am delivery.
        raise AscError(f"the export directory does not exist: {export_path}")

    summary = export_path / "DistributionSummary.plist"
    if summary.is_file():
        with summary.open("rb") as handle:
            found = _find_key(plistlib.load(handle), "buildNumber")
        if found is not None:
            return found, str(summary)

    ipas = sorted(export_path.glob("*.ipa"))
    if len(ipas) == 1:
        with zipfile.ZipFile(ipas[0]) as archive:
            names = [
                name
                for name in archive.namelist()
                if name.startswith("Payload/") and name.endswith(".app/Info.plist")
            ]
        if len(names) == 1:
            with zipfile.ZipFile(ipas[0]) as archive:
                info = plistlib.loads(archive.read(names[0]))
            version = info.get("CFBundleVersion")
            if isinstance(version, str) and version.strip():
                return version.strip(), f"{ipas[0]}!{names[0]}"

    listing = ", ".join(sorted(entry.name for entry in export_path.iterdir())) or "(empty)"
    raise AscError(
        "could not determine the uploaded build number from the export at "
        f"{export_path}. Neither DistributionSummary.plist nor a single .ipa's "
        f"Info.plist yielded one. The export directory contains: {listing}"
    )


# --- App Store Connect -------------------------------------------------------


def find_app_id(transport: Transport, token: str, bundle_id: str) -> str:
    url = f"{ASC_API_ROOT}/v1/apps?filter%5BbundleId%5D={bundle_id}&limit=1"
    payload = transport("GET", url, None, token) or {}
    data = payload.get("data") or []
    if not data:
        raise AscError(f"App Store Connect has no app with bundle id {bundle_id}.")
    return data[0]["id"]


def find_build_id(
    transport: Transport,
    token: str,
    app_id: str,
    build_number: str,
    attempts: int,
    delay_seconds: float,
    sleep: Callable[[float], None] = time.sleep,
) -> str:
    """Poll for the just-uploaded build, then give up loudly.

    App Store Connect does not list a build the instant ``-exportArchive``
    returns, so a single lookup would fail for timing reasons rather than real
    ones. Bounded polling distinguishes "not there yet" from "not there".
    """
    url = (
        f"{ASC_API_ROOT}/v1/builds?filter%5Bapp%5D={app_id}"
        f"&filter%5Bversion%5D={build_number}&limit=1"
    )
    for attempt in range(1, attempts + 1):
        data = (transport("GET", url, None, token) or {}).get("data") or []
        if data:
            return data[0]["id"]
        if attempt < attempts:
            print(
                f"Build {build_number} is not listed yet "
                f"(attempt {attempt}/{attempts}); waiting {delay_seconds:.0f}s."
            )
            sleep(delay_seconds)
    raise AscError(
        f"build {build_number} never appeared in App Store Connect after "
        f"{attempts} attempts. The upload may still be processing; the notes "
        "were not written."
    )


def existing_localizations(transport: Transport, token: str, build_id: str) -> Dict[str, str]:
    url = f"{ASC_API_ROOT}/v1/builds/{build_id}/betaBuildLocalizations?limit=200"
    payload = transport("GET", url, None, token) or {}
    result: Dict[str, str] = {}
    for item in payload.get("data") or []:
        locale = (item.get("attributes") or {}).get("locale")
        if isinstance(locale, str):
            result[locale] = item["id"]
    return result


def publish_notes(
    transport: Transport,
    token: str,
    build_id: str,
    notes: Sequence[Dict[str, str]],
) -> List[str]:
    """Create or update one betaBuildLocalization per locale. Returns locales."""
    existing = existing_localizations(transport, token, build_id)
    written: List[str] = []
    for note in notes:
        locale = note["language"]
        if locale in existing:
            transport(
                "PATCH",
                f"{ASC_API_ROOT}/v1/betaBuildLocalizations/{existing[locale]}",
                {
                    "data": {
                        "type": "betaBuildLocalizations",
                        "id": existing[locale],
                        "attributes": {"whatsNew": note["text"]},
                    }
                },
                token,
            )
            print(f"Updated TestFlight What to Test for {locale} ({len(note['text'])} characters).")
        else:
            transport(
                "POST",
                f"{ASC_API_ROOT}/v1/betaBuildLocalizations",
                {
                    "data": {
                        "type": "betaBuildLocalizations",
                        "attributes": {"locale": locale, "whatsNew": note["text"]},
                        "relationships": {
                            "build": {"data": {"type": "builds", "id": build_id}}
                        },
                    }
                },
                token,
            )
            print(f"Created TestFlight What to Test for {locale} ({len(note['text'])} characters).")
        written.append(locale)
    return written


# --- entry point -------------------------------------------------------------


def read_notes(repo_root: Path) -> List[Dict[str, str]]:
    """Load the iOS notes through the shared formatter, not a second parser."""
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    import prepare_testflight_notes as formatter  # noqa: E402  (path set above)

    try:
        source = formatter.resolve_source("ios", repo_root)
    except formatter.NoSourceError as error:
        # Same reading as an empty note file: the repository has nothing to say
        # about this build. Raising here would fail a job whose upload already
        # succeeded, over the absence of a file rather than a real fault.
        print(f"warning: {error}; leaving the build's notes unchanged.")
        return []
    print(f"Reading TestFlight What to Test from {source}")
    return formatter.load_notes(source, skip_empty=True)


def main(argv: Optional[Sequence[str]] = None, transport: Transport = urllib_transport) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--export-path", required=True, type=Path)
    parser.add_argument("--repo-root", default=Path.cwd(), type=Path)
    parser.add_argument("--poll-attempts", default=20, type=int)
    parser.add_argument("--poll-seconds", default=30.0, type=float)
    args = parser.parse_args(argv)

    notes = read_notes(args.repo_root)
    if not notes:
        # Not an error: a deliberately empty note file means "nothing to say
        # about this build", and the upload itself already succeeded.
        print("No TestFlight What to Test text to publish; leaving the build's notes unchanged.")
        return 0

    missing = [name for name in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_PATH") if not os.environ.get(name)]
    if missing:
        raise AscError(
            "the runner-local App Store Connect environment is incomplete; missing: "
            + ", ".join(missing)
        )

    build_number, provenance = discover_build_number(args.export_path)
    print(f"Uploaded build number {build_number} (read from {provenance}).")

    token = build_token(
        os.environ["ASC_KEY_ID"], os.environ["ASC_ISSUER_ID"], Path(os.environ["ASC_KEY_PATH"])
    )
    app_id = find_app_id(transport, token, args.bundle_id)
    build_id = find_build_id(
        transport, token, app_id, build_number, args.poll_attempts, args.poll_seconds
    )
    written = publish_notes(transport, token, build_id, notes)
    print(f"TestFlight What to Test published for build {build_number}: {', '.join(written)}.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except AscError as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)

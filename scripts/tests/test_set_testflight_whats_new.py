"""Tests for the App Store Connect What to Test writer (beid#503).

The emi lane cannot be exercised end to end from a pull request — it needs
`GHA_DELIVERY=on`, a runner-local signing key and a real upload — so everything
here is witnessed at the cheapest layer that can still fail:

* the DER-to-raw signature conversion is round-tripped through the real
  `openssl` binary against a throwaway key, because a wrong conversion produces
  a signature that is perfectly well-formed and simply never verifies;
* the build-number discovery is run against synthesized export directories,
  because the *only* thing worse than not writing notes is writing them onto
  another build;
* the request shapes are run against an injected transport, so no test ever
  reaches Apple.
"""

import json
import base64
import plistlib
import shutil
import subprocess
import sys
import unittest
import zipfile
from pathlib import Path
from tempfile import TemporaryDirectory

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "gha"))

import set_testflight_whats_new as writer  # noqa: E402


def make_p256_key(directory: Path) -> Path:
    """A throwaway PKCS#8 P-256 key, the same shape as an ASC .p8."""
    key = directory / "key.p8"
    generated = subprocess.run(
        ["openssl", "ecparam", "-genkey", "-name", "prime256v1", "-noout"],
        capture_output=True, check=True,
    )
    converted = subprocess.run(
        ["openssl", "pkcs8", "-topk8", "-nocrypt"],
        input=generated.stdout, capture_output=True, check=True,
    )
    key.write_bytes(converted.stdout)
    return key


def der_from_raw(raw: bytes) -> bytes:
    """Re-encode raw r||s as DER, so a signature can be handed back to openssl."""
    def encode(value: bytes) -> bytes:
        value = value.lstrip(b"\x00") or b"\x00"
        if value[0] & 0x80:
            value = b"\x00" + value
        return b"\x02" + bytes([len(value)]) + value

    body = encode(raw[:32]) + encode(raw[32:])
    return b"\x30" + bytes([len(body)]) + body


@unittest.skipIf(shutil.which("openssl") is None, "openssl is required to sign")
class SignatureConversionTest(unittest.TestCase):
    def test_a_converted_signature_still_verifies(self) -> None:
        """The round trip openssl -> raw -> openssl, which is the whole risk."""
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            key = make_p256_key(root)
            message = b"eyJhbGciOiJFUzI1NiJ9.eyJpc3MiOiJ0ZXN0In0"

            raw = writer.sign_es256(message, key)
            self.assertEqual(len(raw), 64)

            public = root / "public.pem"
            public.write_bytes(
                subprocess.run(["openssl", "ec", "-in", str(key), "-pubout"],
                               capture_output=True, check=True).stdout
            )
            (root / "sig.der").write_bytes(der_from_raw(raw))
            (root / "msg").write_bytes(message)

            verified = subprocess.run(
                ["openssl", "dgst", "-sha256", "-verify", str(public),
                 "-signature", str(root / "sig.der"), str(root / "msg")],
                capture_output=True, check=False,
            )
            self.assertEqual(verified.returncode, 0, verified.stderr.decode())

    def test_every_signature_of_a_batch_is_exactly_64_bytes(self) -> None:
        """Short coordinates are the case a naive conversion gets wrong.

        r or s occasionally has leading zero bytes, which DER drops; without the
        left-pad the result is 63 bytes and Apple rejects the token. One key
        signing many messages reaches that case in practice.
        """
        with TemporaryDirectory() as tmp:
            key = make_p256_key(Path(tmp))
            for index in range(40):
                with self.subTest(index=index):
                    self.assertEqual(len(writer.sign_es256(f"m{index}".encode(), key)), 64)


class DerParsingTest(unittest.TestCase):
    def test_a_one_byte_coordinate_is_left_padded(self) -> None:
        der = der_from_raw(b"\x00" * 31 + b"\x01" + b"\x02" * 32)

        raw = writer.der_to_raw_signature(der)

        self.assertEqual(len(raw), 64)
        self.assertEqual(raw[:32], b"\x00" * 31 + b"\x01")
        self.assertEqual(raw[32:], b"\x02" * 32)

    def test_a_high_bit_coordinate_keeps_its_value(self) -> None:
        """DER prefixes 0x00 to keep the integer positive; raw must drop it."""
        der = der_from_raw(b"\xff" * 32 + b"\x80" + b"\x00" * 31)

        raw = writer.der_to_raw_signature(der)

        self.assertEqual(raw[:32], b"\xff" * 32)
        self.assertEqual(raw[32:], b"\x80" + b"\x00" * 31)

    def test_a_non_sequence_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            writer.der_to_raw_signature(b"\x31" + b"\x00" * 16)


@unittest.skipIf(shutil.which("openssl") is None, "openssl is required to sign")
class TokenTest(unittest.TestCase):
    def test_the_token_carries_the_fields_apple_requires(self) -> None:
        with TemporaryDirectory() as tmp:
            key = make_p256_key(Path(tmp))

            token = writer.build_token("KEYID", "ISSUERID", key, now=1_000_000)

            header_b64, payload_b64, signature_b64 = token.split(".")
            def decode(part: str):
                return json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)))

            self.assertEqual(decode(header_b64), {"alg": "ES256", "kid": "KEYID", "typ": "JWT"})
            payload = decode(payload_b64)
            self.assertEqual(payload["iss"], "ISSUERID")
            self.assertEqual(payload["aud"], "appstoreconnect-v1")
            self.assertEqual(payload["iat"], 1_000_000)
            self.assertLessEqual(payload["exp"] - payload["iat"], 20 * 60)
            self.assertEqual(
                len(base64.urlsafe_b64decode(signature_b64 + "=" * (-len(signature_b64) % 4))), 64
            )


class BuildNumberDiscoveryTest(unittest.TestCase):
    def _export_with_summary(self, root: Path, build_number: str) -> Path:
        export = root / "export"
        export.mkdir()
        # The shape xcodebuild writes: a dict keyed by the exported ipa name.
        with (export / "DistributionSummary.plist").open("wb") as handle:
            plistlib.dump(
                {"Beid.ipa": [{"versionNumber": "1.0", "buildNumber": build_number}]}, handle
            )
        return export

    def _export_with_ipa(self, root: Path, build_number: str) -> Path:
        export = root / "export"
        export.mkdir(exist_ok=True)
        with zipfile.ZipFile(export / "Beid.ipa", "w") as archive:
            archive.writestr(
                "Payload/Beid.app/Info.plist",
                plistlib.dumps({"CFBundleVersion": build_number, "CFBundleShortVersionString": "1.0"}),
            )
        return export

    def test_it_is_read_from_the_distribution_summary(self) -> None:
        with TemporaryDirectory() as tmp:
            export = self._export_with_summary(Path(tmp), "77")

            value, provenance = writer.discover_build_number(export)

            self.assertEqual(value, "77")
            self.assertIn("DistributionSummary.plist", provenance)

    def test_the_ipa_is_the_second_reading_when_no_summary_exists(self) -> None:
        with TemporaryDirectory() as tmp:
            export = self._export_with_ipa(Path(tmp), "91")

            value, provenance = writer.discover_build_number(export)

            self.assertEqual(value, "91")
            self.assertIn(".ipa", provenance)

    def test_an_undiscoverable_build_number_fails_and_lists_what_was_there(self) -> None:
        """No 'most recent build' fallback: a guess writes onto another build."""
        with TemporaryDirectory() as tmp:
            export = Path(tmp) / "export"
            export.mkdir()
            (export / "Packaging.log").write_text("nothing useful", encoding="utf-8")

            with self.assertRaises(writer.AscError) as caught:
                writer.discover_build_number(export)

            self.assertIn("Packaging.log", str(caught.exception))


class RecordingTransport:
    """Answers App Store Connect's shape without a network."""

    def __init__(self, localizations=(), builds=(("BUILDID",),)):
        self.calls = []
        self._localizations = list(localizations)
        self._build_pages = list(builds)

    def __call__(self, method, url, body, token):
        self.calls.append((method, url, body))
        if "/v1/apps?" in url:
            return {"data": [{"id": "APPID"}]}
        if "/v1/builds?" in url:
            page = self._build_pages.pop(0) if self._build_pages else ()
            return {"data": [{"id": page[0]}] if page else []}
        if url.endswith("betaBuildLocalizations?limit=200"):
            return {"data": [
                {"id": f"LOC-{locale}", "attributes": {"locale": locale}}
                for locale in self._localizations
            ]}
        return {"data": {"id": "NEW"}}


class PublicationTest(unittest.TestCase):
    def test_an_existing_locale_is_patched_not_duplicated(self) -> None:
        transport = RecordingTransport(localizations=["en-US"])

        written = writer.publish_notes(
            transport, "token", "BUILDID", [{"language": "en-US", "text": "hello"}]
        )

        self.assertEqual(written, ["en-US"])
        methods = [call[0] for call in transport.calls]
        self.assertIn("PATCH", methods)
        self.assertNotIn("POST", methods)
        patch = next(call for call in transport.calls if call[0] == "PATCH")
        self.assertEqual(patch[1].rsplit("/", 1)[-1], "LOC-en-US")
        self.assertEqual(patch[2]["data"]["attributes"]["whatsNew"], "hello")

    def test_a_new_locale_is_created_against_this_build(self) -> None:
        transport = RecordingTransport(localizations=[])

        writer.publish_notes(
            transport, "token", "BUILDID", [{"language": "ja", "text": "こんにちは"}]
        )

        post = next(call for call in transport.calls if call[0] == "POST")
        data = post[2]["data"]
        self.assertEqual(data["attributes"], {"locale": "ja", "whatsNew": "こんにちは"})
        self.assertEqual(data["relationships"]["build"]["data"]["id"], "BUILDID")

    def test_the_build_lookup_filters_on_the_uploaded_build_number(self) -> None:
        transport = RecordingTransport()

        build_id = writer.find_build_id(transport, "token", "APPID", "77", 1, 0.0)

        self.assertEqual(build_id, "BUILDID")
        url = next(call[1] for call in transport.calls if "/v1/builds?" in call[1])
        self.assertIn("filter%5Bapp%5D=APPID", url)
        self.assertIn("filter%5Bversion%5D=77", url)

    def test_a_build_that_never_appears_fails_rather_than_taking_another(self) -> None:
        transport = RecordingTransport(builds=[(), (), ()])
        slept = []

        with self.assertRaises(writer.AscError) as caught:
            writer.find_build_id(
                transport, "token", "APPID", "77", 3, 30.0, sleep=slept.append
            )

        self.assertIn("77", str(caught.exception))
        self.assertEqual(len(slept), 2)  # waits between attempts, not after the last


class EmptyNotesTest(unittest.TestCase):
    def test_nothing_is_sent_when_there_is_no_text(self) -> None:
        """A deliberately empty note file leaves the build's notes alone."""
        transport = RecordingTransport()
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "what_to_test.json").write_text(
                json.dumps([{"language": "en-US", "text": "  "}]), encoding="utf-8"
            )

            code = writer.main(
                ["--bundle-id", "org.levarac.beid", "--export-path", str(root),
                 "--repo-root", str(root)],
                transport=transport,
            )

            self.assertEqual(code, 0)
            self.assertEqual(transport.calls, [])


if __name__ == "__main__":
    unittest.main()

import tempfile
import stat
import subprocess
from pathlib import Path
import unittest
from unittest import mock
from checkpoint_bundle import FILES, RECEIPT, digest, stage_bundle, verify_bundle


class BundleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.parent = Path(self.temp.name)
        self.root = self.parent / "bundle"
        (self.root / "rom").mkdir(parents=True)
        for name in FILES:
            (self.root / name).write_bytes(name.encode())
        self.seal()

    def seal(self):
        (self.root / RECEIPT).write_text("".join(
            f"{digest(self.root / name)}  {name}\n" for name in sorted(FILES)))

    def test_good_and_private_copy(self):
        self.assertEqual(verify_bundle(self.root), self.root)
        staged = stage_bundle(self.root, self.parent / "replay")
        (staged / "guest.vhd").write_bytes(b"guest writes")
        self.assertEqual((self.root / "guest.vhd").read_bytes(), b"guest.vhd")
        with self.assertRaises(ValueError):
            verify_bundle(staged)

    def test_each_changed_artifact_rejected(self):
        for name in FILES:
            with self.subTest(name=name):
                (self.root / name).write_bytes(b"wrong content")
                with self.assertRaises(ValueError):
                    verify_bundle(self.root)
                (self.root / name).write_bytes(name.encode())

    def test_readonly_archive_stages_only_writable_private_disk(self):
        for name in FILES:
            (self.root / name).chmod(0o444)
        (self.root / "ao486sim_ven").chmod(0o555)
        modes = {name: stat.S_IMODE((self.root / name).stat().st_mode)
                 for name in FILES}
        staged = stage_bundle(self.root, self.parent / "replay")
        for name in FILES:
            self.assertEqual(stat.S_IMODE((self.root / name).stat().st_mode), modes[name])
            expected = modes[name] | (stat.S_IWUSR if name == "guest.vhd" else 0)
            self.assertEqual(stat.S_IMODE((staged / name).stat().st_mode), expected)
        verify_bundle(self.root)
        verify_bundle(staged)
        with (staged / "guest.vhd").open("r+b") as disk:
            disk.write(b"new")
        verify_bundle(self.root)

    def test_cold_capture_private_disk_copy_with_readonly_input(self):
        # Exercise the actual copy/permission stanza without launching a guest
        # or weakening the capture script's serialized-resource boundary.
        script = (Path(__file__).resolve().parents[1] / "ao486-sim/ven/run-gameplay-capture.sh").read_text()
        start = script.index("cp --reflink=auto --sparse=always boot.vhd guest.vhd\n")
        end = script.index("printf 'cold_reset=", start)
        boot = self.parent / "boot.vhd"
        boot.write_bytes(b"immutable cold input")
        boot.chmod(0o444)
        subprocess.run(["bash", "-euc", script[start:end]], cwd=self.parent, check=True)
        guest = self.parent / "guest.vhd"
        self.assertEqual(stat.S_IMODE(boot.stat().st_mode), 0o444)
        self.assertTrue(guest.stat().st_mode & stat.S_IWUSR)
        self.assertEqual(guest.read_bytes(), boot.read_bytes())
        with guest.open("r+b") as disk:
            disk.write(b"modified")
        self.assertEqual(boot.read_bytes(), b"immutable cold input")

    def test_sparse_archive_disk_keeps_holes_and_private_writes(self):
        disk = self.root / "guest.vhd"
        with disk.open("wb") as stream:
            stream.write(b"boot sector")
            stream.seek(4 * 1024 * 1024 + 127)
            stream.write(b"allocated data after a hole")
            stream.truncate(8 * 1024 * 1024 + 31)
        disk.chmod(0o444)
        before = disk.stat()
        if before.st_blocks * 512 >= before.st_size // 2:
            self.skipTest("test filesystem does not provide sparse files")
        self.seal()
        original_sha = digest(disk)
        staged = stage_bundle(self.root, self.parent / "sparse-replay")
        private = staged / "guest.vhd"
        self.assertEqual(private.stat().st_size, before.st_size)
        self.assertEqual(digest(private), original_sha)
        self.assertLess(private.stat().st_blocks * 512, before.st_size // 2,
                        "checkpoint staging expanded sparse disk holes")
        self.assertEqual(stat.S_IMODE(disk.stat().st_mode), 0o444)
        with private.open("r+b") as stream:
            stream.seek(2 * 1024 * 1024)
            stream.write(b"private guest write into a hole")
        self.assertEqual(digest(disk), original_sha)
        self.assertNotEqual(digest(private), original_sha)
        verify_bundle(self.root)

    def test_sparse_copy_failure_is_not_hidden_by_dense_fallback(self):
        out = self.parent / "failed-replay"
        with mock.patch("checkpoint_bundle.subprocess.run",
                        side_effect=subprocess.CalledProcessError(1, ["cp"])):
            with self.assertRaises(subprocess.CalledProcessError):
                stage_bundle(self.root, out)
        self.assertTrue(out.is_dir())
        self.assertFalse((out / "guest.vhd").exists())
        verify_bundle(self.root)

    def test_duplicate_and_traversal_rejected(self):
        for name in ("guest.vhd", "../outside"):
            self.seal()
            with (self.root / RECEIPT).open("a") as stream:
                stream.write(f"{'0' * 64}  {name}\n")
            with self.assertRaises(ValueError):
                verify_bundle(self.root)

    def test_missing_receipt_member(self):
        text = (self.root / RECEIPT).read_text().splitlines()
        (self.root / RECEIPT).write_text("\n".join(text[:-1]) + "\n")
        with self.assertRaises(ValueError):
            verify_bundle(self.root)

    def test_symlink_rejected(self):
        disk = self.root / "guest.vhd"
        outside = self.parent / "disk"
        disk.rename(outside)
        disk.symlink_to(outside)
        with self.assertRaises(ValueError):
            verify_bundle(self.root)

    def test_existing_destination_untouched(self):
        out = self.parent / "existing"
        out.mkdir()
        marker = out / "keep"
        marker.write_text("valuable")
        with self.assertRaises(FileExistsError):
            stage_bundle(self.root, out)
        self.assertEqual(marker.read_text(), "valuable")


if __name__ == "__main__":
    unittest.main()

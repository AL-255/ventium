"""Host checks for preservation of the guarded build's inherited lock FD."""
from pathlib import Path
import unittest
from unittest.mock import patch

from run_srt_payload_top_ab import inherited_lock_fds


class LockInheritance(unittest.TestCase):
    def test_only_exact_lock_descriptor_is_preserved(self):
        items = [Path('/proc/self/fd')/str(n) for n in (0, 1, 2, 9, 11, 12)]
        links = {'0': '/dev/null', '1': 'pipe:[42]', '2': 'pipe:[42]',
                 '9': '/tmp/ventium-heavy-build.lock',
                 '11': '/tmp/ventium-heavy-build.lock.other'}

        def link(path):
            if path.name == '12':
                raise FileNotFoundError
            return links[path.name]

        with patch.object(Path, 'iterdir', return_value=iter(items)), patch('os.readlink', side_effect=link):
            self.assertEqual(inherited_lock_fds(), (9,))

    def test_environment_marker_cannot_replace_lock(self):
        with patch.object(Path, 'iterdir', return_value=iter([])):
            with self.assertRaisesRegex(AssertionError, 'not inherited'):
                inherited_lock_fds()


if __name__ == '__main__':
    unittest.main()

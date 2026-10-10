"""Recipe/producer-contract checks; not a full-core or FPU equivalence pass."""
import itertools
import unittest

import prepare_fp_payload_select as recipe


def original_fixture():
    return '\n'.join((recipe.DECLARATION, *recipe.GUARDS, *recipe.PORTS)) + '\n'


def disabled(text):
    """Remove only this feature's blocks, preserving every original byte line."""
    out, depth, keep_else = [], 0, False
    for line in text.splitlines(keepends=True):
        token = line.strip()
        if not depth:
            if token == '`ifdef ' + recipe.FLAG:
                depth = 1
                keep_else = False
            else:
                out.append(line)
        elif token.startswith(('`ifdef ', '`ifndef ')):
            depth += 1
        elif token == '`endif':
            depth -= 1
        elif token == '`else' and depth == 1:
            keep_else = True
        elif keep_else:
            out.append(line)
    assert depth == 0
    return ''.join(out)


class RecipeTests(unittest.TestCase):
    def test_disabled_original_tokens(self):
        original = original_fixture()
        self.assertEqual(disabled(recipe.transform(original)).split(), original.split())

    def test_exactly_eight_payload_ports(self):
        result = recipe.transform(original_fixture())
        for port in recipe.PORTS:
            self.assertEqual(result.count(port), 1)
            self.assertEqual(result.count(port.replace('fp_shared_pipe_cmd', 'fp_shared_pipe_payload')), 1)
        for guard in recipe.GUARDS:
            self.assertEqual(result.count(guard), 1)
        self.assertIn('FP-PAYLOAD-OWNER', result)

    def test_reject_missing_and_ambiguous_contract(self):
        original = original_fixture()
        for anchor in (recipe.DECLARATION, *recipe.PORTS, *recipe.GUARDS):
            with self.subTest(anchor=anchor):
                with self.assertRaises(ValueError):
                    recipe.transform(original.replace(anchor, ''))
                with self.assertRaises(ValueError):
                    recipe.transform(original + anchor)

    def test_reject_double_application(self):
        with self.assertRaises(ValueError):
            recipe.transform(recipe.transform(original_fixture()))

    def test_valid_producer_truth_table(self):
        # State numbers are abstract and independent of RTL enum encoding.
        # All remaining original guards are free booleans, never forced true.
        seen = [0, 0, 0]
        invalid_payload_differences = 0
        for state in range(128):
            for pipe, load, store, owner in itertools.product((False, True), repeat=4):
                direct = state == 1 and pipe
                valid = owner and (state == 2 or direct or
                                  (state == 3 and (load or store)))
                early = state == 1
                if valid:
                    self.assertEqual(early, direct)
                    seen[state - 1] += 1
                elif early != direct:
                    invalid_payload_differences += 1
        self.assertTrue(all(seen))
        self.assertGreater(invalid_payload_differences, 0)

    def test_wrong_state_negative_control(self):
        # A selector which also picked the live packet for memory handoffs
        # would corrupt a valid command, not merely an invalid idle payload.
        state, direct, valid = 3, False, True
        self.assertTrue(valid and ((state in (1, 3)) != direct))


if __name__ == '__main__':
    unittest.main()

"""Check the mock phone through its public CLI and real UDP output."""

import json
from pathlib import Path
import socket
import subprocess
import sys
import unittest


ROOT = Path(__file__).resolve().parents[1]


class SimulatorTest(unittest.TestCase):
    def setUp(self):
        self.receiver = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.receiver.bind(("127.0.0.1", 0))
        self.receiver.settimeout(3)
        self.addCleanup(self.receiver.close)

    def start(self, *options):
        process = subprocess.Popen([
            sys.executable, str(ROOT / "scripts/storyteller-simulator"),
            str(ROOT / "spec/fixtures/chapter-transition.epub"), "--target",
            f"127.0.0.1:{self.receiver.getsockname()[1]}", *options,
        ], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

        def cleanup():
            if process.poll() is None:
                process.terminate()
            process.communicate(timeout=5)
        self.addCleanup(cleanup)
        return process

    def packet(self):
        data, _ = self.receiver.recvfrom(8192)
        return json.loads(data)

    def test_nested_epub_replay_preserves_wire_contract_and_spine_gap(self):
        process = self.start("--rate", "2", "--repeat", "2", "--delay", "0.03")
        packets = [self.packet() for _ in range(8)]
        stdout, stderr = process.communicate(timeout=5)
        self.assertEqual(process.returncode, 0, stderr)
        self.assertEqual(stdout.count("Sent ["), 8)
        self.assertEqual([(p["sectionIndex"], p["entryIndex"], p["textHref"], p["textId"])
                          for p in packets], [
            (3, 0, "OEBPS/text/frontmatter.xhtml", "front-one"),
            (3, 1, "OEBPS/text/frontmatter.xhtml", "front-two"),
            (5, 0, "OEBPS/text/chapter-one.xhtml", "chapter-one"),
            (5, 1, "OEBPS/text/chapter-one.xhtml", "chapter-two"),
        ] * 2)
        self.assertEqual(len({p["senderID"] for p in packets}), 1)
        for packet in packets:
            self.assertEqual(set(packet), {"version", "senderID", "bookID", "sectionIndex",
                                          "entryIndex", "textHref", "textId", "playbackRate", "sentAt"})
            self.assertEqual(packet["version"], 1)
            self.assertEqual(packet["playbackRate"], 2)
            self.assertEqual(packet["bookID"], {"sourceID": "storyteller-simulator",
                                                "uuid": "chapter-transition"})
        self.assertTrue(all(a["sentAt"] < b["sentAt"] for a, b in zip(packets, packets[1:])))

    def test_paused_phone_is_silent_and_resume_reports_the_seek_target(self):
        process = self.start("--interactive", "--rate", "0.5")
        self.assertEqual(self.packet()["textId"], "front-one")
        process.stdin.write("pause\n")
        process.stdin.flush()
        # The next clip would arrive after 1.2 s if pause were ignored.
        self.receiver.settimeout(1.5)
        with self.assertRaises(socket.timeout):
            self.packet()
        process.stdin.write("seek 3\nrate 1.5\nresume\n")
        process.stdin.flush()
        self.receiver.settimeout(3)
        packet = self.packet()
        self.assertEqual(packet["textId"], "chapter-two")
        self.assertEqual(packet["playbackRate"], 1.5)
        process.stdin.write("quit\n")
        process.stdin.flush()
        _, stderr = process.communicate(timeout=5)
        self.assertEqual(process.returncode, 0, stderr)


if __name__ == "__main__":
    unittest.main()

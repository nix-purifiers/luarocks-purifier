# SPDX-License-Identifier: MIT
#
# Unit tests of bin/luarocks-purifier: how it reads what LuaRocks runs, how
# it names and places what the lock run records, how it reads its options,
# and how its tool stand-ins serve the locked files offline.
#
#   python3 -m unittest tests/test_cli.py

import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
import pathlib
import tempfile
import typing
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "bin" / "luarocks-purifier"
loader = importlib.machinery.SourceFileLoader("luarocks_purifier", str(SCRIPT))
spec = importlib.util.spec_from_loader("luarocks_purifier", loader)
assert spec is not None
cli = importlib.util.module_from_spec(spec)
loader.exec_module(cli)


@contextlib.contextmanager
def in_dir(path):
    before = os.getcwd()
    os.chdir(path)
    try:
        yield
    finally:
        os.chdir(before)


def fails_with(test, text, fn, *args):
    stderr = io.StringIO()
    with contextlib.redirect_stderr(stderr), test.assertRaises(SystemExit):
        fn(*args)
    test.assertIn(text, stderr.getvalue())


class CurlRequest(unittest.TestCase):
    def test_download(self):
        args = ["-f", "-L", "--user-agent", "LuaRocks/3.13.0 x via curl", "https://luarocks.org/a-1.0-1.rockspec", "--output", "/t/a"]
        self.assertEqual(cli.curl_request(args), ("https://luarocks.org/a-1.0-1.rockspec", "/t/a"))

    def test_named_output_forms(self):
        for flags in (["-o", "/t/a"], ["-o/t/a"], ["--output=/t/a"]):
            self.assertEqual(cli.curl_request(["https://x.org/a", *flags]), ("https://x.org/a", "/t/a"))

    def test_cached_download(self):
        args = ["-f", "-L", "-R", "-z", "/t/m.zip", "https://luarocks.org/manifest-5.4.zip", "--output", "/t/m.zip"]
        self.assertEqual(cli.curl_request(args), ("https://luarocks.org/manifest-5.4.zip", "/t/m.zip"))

    def test_no_output(self):
        self.assertEqual(cli.curl_request(["https://x.org/a"]), ("https://x.org/a", None))


class GitUrls(unittest.TestCase):
    def test_https(self):
        self.assertEqual(cli.https_git_url("https://github.com/a/b.git"), "https://github.com/a/b.git")

    def test_git_plus_https(self):
        self.assertEqual(cli.https_git_url("git+https://github.com/a/b.git"), "https://github.com/a/b.git")

    def test_git_protocol(self):
        self.assertEqual(cli.https_git_url("git://github.com/a/b.git"), "https://github.com/a/b.git")

    def test_ssh_url(self):
        self.assertEqual(cli.https_git_url("ssh://git@github.com/a/b.git"), "https://github.com/a/b.git")

    def test_ssh_url_with_port(self):
        self.assertEqual(cli.https_git_url("ssh://git@example.org:2222/a/b.git"), "https://example.org/a/b.git")

    def test_scp_form(self):
        self.assertEqual(cli.https_git_url("git@github.com:a/b.git"), "https://github.com/a/b.git")


class Servers(unittest.TestCase):
    servers: typing.ClassVar = [["rocks"], cli.DEFAULT_SERVERS[0]]

    def test_remote(self):
        self.assertTrue(cli.is_remote("https://luarocks.org"))
        self.assertTrue(cli.is_remote("file:///srv/rocks"))
        self.assertFalse(cli.is_remote("rocks"))

    def test_group_of_a_server_file(self):
        group, base = cli.server_group("https://luarocks.org/lpeg-1.1.0-2.src.rock", self.servers)
        self.assertEqual(base, "https://luarocks.org")
        self.assertEqual(group, cli.DEFAULT_SERVERS[0])

    def test_group_of_a_mirror_file(self):
        url = "https://loadk.com/luarocks/lpeg-1.1.0-2.src.rock"
        self.assertEqual(cli.server_group(url, self.servers)[1], "https://loadk.com/luarocks")

    def test_other_files_have_no_group(self):
        self.assertEqual(cli.server_group("https://github.com/a/b/archive/v1.tar.gz", self.servers), (None, None))
        # A file below a server's root is not a server file.
        self.assertEqual(cli.server_group("https://luarocks.org/manifests/x/a.rockspec", self.servers), (None, None))

    def test_resolve_for_the_lock_run(self):
        resolved = cli.resolve_servers(self.servers, "/work")
        self.assertEqual(resolved, [["/work/rocks"], cli.DEFAULT_SERVERS[0]])

    def test_resolve_offline(self):
        resolved = cli.resolve_servers(self.servers + [["https://other.org"]], "/src", offline="/cache/server")
        self.assertEqual(resolved, [["/src/rocks"], ["/cache/server"]])


class Names(unittest.TestCase):
    def test_lua_abi(self):
        self.assertEqual(cli.lua_abi("luajit"), "5.1")
        self.assertEqual(cli.lua_abi("5.4"), "5.4")

    def test_checkout_key(self):
        self.assertEqual(cli.checkout_key("git", "https://x/a.git", None), "git https://x/a.git ")
        self.assertEqual(cli.checkout_key("hg", "https://x/a", "1.0"), "hg https://x/a 1.0")

    def test_short_hash_is_stable(self):
        self.assertEqual(cli.short_hash("x"), cli.short_hash("x"))
        self.assertEqual(len(cli.short_hash("x")), 16)

    def test_positional(self):
        self.assertEqual(cli.positional(["--depth=1", "--branch=v1", "u", "m"]), ["u", "m"])
        self.assertEqual(cli.positional(["--rev", "1.0", "u", "m"], skip_with_value=("--rev",)), ["u", "m"])

    def test_lua_string(self):
        self.assertEqual(cli.lua_string('a"b\\c'), '"a\\"b\\\\c"')


class DefinitionHash(unittest.TestCase):
    def test_changes_with_a_rockspec_and_luarocks_lock(self):
        with tempfile.TemporaryDirectory() as d:
            p = pathlib.Path(d)
            (p / "a-1.0-1.rockspec").write_text("package = 'a'\n")
            first = cli.definition_hash(["a-1.0-1.rockspec"], d)
            (p / "a-1.0-1.rockspec").write_text("package = 'a' -- changed\n")
            second = cli.definition_hash(["a-1.0-1.rockspec"], d)
            (p / "luarocks.lock").write_text("return {}\n")
            third = cli.definition_hash(["a-1.0-1.rockspec"], d)
        self.assertEqual(len({first, second, third}), 3)
        self.assertTrue(first.startswith("sha256-"))


class LockOptions(unittest.TestCase):
    def project(self, d):
        (pathlib.Path(d) / "a-1.0-1.rockspec").write_text("package = 'a'\n")
        os.makedirs(os.path.join(d, "rocks"))

    def test_defaults(self):
        with tempfile.TemporaryDirectory() as d, in_dir(d):
            self.project(d)
            opts = cli.lock_options([], None)
        self.assertEqual(opts["lua"], "5.4")
        self.assertEqual(opts["servers"], cli.DEFAULT_SERVERS)
        self.assertEqual(opts["rockspecs"], ["a-1.0-1.rockspec"])

    def test_options(self):
        with tempfile.TemporaryDirectory() as d, in_dir(d):
            self.project(d)
            opts = cli.lock_options(["--lua", "luajit", "--server", "./rocks", "--external-dep", "zlib"], None)
        self.assertEqual(opts["lua"], "luajit")
        self.assertEqual(opts["servers"], [["rocks"]] + cli.DEFAULT_SERVERS)
        self.assertEqual(opts["externalDeps"], ["zlib"])

    def test_only_server(self):
        with tempfile.TemporaryDirectory() as d, in_dir(d):
            self.project(d)
            opts = cli.lock_options(["--only-server", "https://rocks.example.org/"], None)
        self.assertEqual(opts["servers"], [["https://rocks.example.org"]])

    def test_previous_options_are_kept(self):
        previous = {"lua": "5.1", "servers": [["rocks"]], "externalDeps": ["zlib"], "rockspecs": []}
        with tempfile.TemporaryDirectory() as d, in_dir(d):
            self.project(d)
            opts = cli.lock_options([], previous)
        self.assertEqual((opts["lua"], opts["servers"], opts["externalDeps"]), ("5.1", [["rocks"]], ["zlib"]))

    def test_bad_lua(self):
        with tempfile.TemporaryDirectory() as d, in_dir(d):
            self.project(d)
            fails_with(self, "--lua takes one of", cli.lock_options, ["--lua", "6.0"], None)

    def test_server_outside_the_project(self):
        with tempfile.TemporaryDirectory() as d, in_dir(d):
            self.project(d)
            fails_with(self, "outside the project", cli.lock_options, ["--server", "/srv/rocks"], None)

    def test_no_rockspec(self):
        with tempfile.TemporaryDirectory() as d, in_dir(d):
            fails_with(self, "no *.rockspec", cli.lock_options, [], None)


class Serving(unittest.TestCase):
    def cache(self, d):
        locked = pathlib.Path(d) / "locked.tar.gz"
        locked.write_bytes(b"archive")
        checkout = pathlib.Path(d) / "checkout"
        checkout.mkdir()
        (checkout / "a.lua").write_text("return 1\n")
        (pathlib.Path(d) / "files.json").write_text(json.dumps({"https://x.org/a.tar.gz": str(locked)}))
        (pathlib.Path(d) / "checkouts.json").write_text(
            json.dumps({"git https://x.org/a.git v1": {"path": str(checkout), "identifier": "2020-01-01 00:00:00 +0000_abc1234"}})
        )
        os.environ.update({"LUAROCKS_PURIFIER_MODE": "serve", "LUAROCKS_PURIFIER_CACHE": d})
        os.environ.pop("LUAROCKS_PURIFIER_SELF", None)

    def test_serves_a_locked_file(self):
        with tempfile.TemporaryDirectory() as d:
            self.cache(d)
            out = os.path.join(d, "out")
            self.assertEqual(cli.tool_curl(["-f", "-L", "https://x.org/a.tar.gz", "--output", out]), 0)
            self.assertEqual(pathlib.Path(out).read_bytes(), b"archive")

    def test_a_file_missing_from_the_lock(self):
        with tempfile.TemporaryDirectory() as d:
            self.cache(d)
            fails_with(self, "luarocks-purifier lock", cli.tool_curl, ["https://x.org/b.tar.gz", "--output", os.path.join(d, "b")])

    def test_a_remote_manifest_is_not_served(self):
        with tempfile.TemporaryDirectory() as d:
            self.cache(d)
            self.assertNotEqual(cli.tool_curl(["https://luarocks.org/manifest-5.4.zip", "--output", os.path.join(d, "m")]), 0)

    def test_serves_a_git_checkout_and_its_identifier(self):
        with tempfile.TemporaryDirectory() as d, in_dir(d):
            self.cache(d)
            self.assertEqual(cli.tool_git(["clone", "--depth=1", "--branch=v1", "https://x.org/a.git", "a"]), 0)
            self.assertEqual((pathlib.Path(d) / "a" / "a.lua").read_text(), "return 1\n")
            with in_dir(os.path.join(d, "a")):
                out = io.StringIO()
                with contextlib.redirect_stdout(out):
                    cli.tool_git(["log", "--pretty=format:%ai_%h", "-n", "1"])
            self.assertEqual(out.getvalue(), "2020-01-01 00:00:00 +0000_abc1234")

    def test_a_checkout_missing_from_the_lock(self):
        with tempfile.TemporaryDirectory() as d, in_dir(d):
            self.cache(d)
            fails_with(self, "is not in", cli.tool_git, ["clone", "--depth=1", "https://x.org/b.git", "b"])

    def test_surround_scm_is_refused(self):
        fails_with(self, "Surround SCM", cli.tool_sscm, ["get", "*"])


if __name__ == "__main__":
    unittest.main()

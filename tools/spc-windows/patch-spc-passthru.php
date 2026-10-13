<?php

/*
 * Patch spc-windows-x64.exe so Shell::passthru() can no longer deadlock on a
 * child that writes to stderr.
 *
 *   php -d phar.readonly=0 patch-spc-passthru.php <spc-windows-x64.exe> <out.exe>
 *
 * The bug (spc fork v3.0.0-pgo-rc19 and later, commit d064211e "give Windows
 * children pipe std handles instead of sockets"): on Windows, passthru() gives
 * the child two anonymous pipes (stdout, stderr) and polls them in turn with
 * fread() after stream_set_blocking($pipe, false). PHP cannot make an
 * anonymous pipe non-blocking on Windows. stream_set_blocking() is a no-op
 * there (no O_NONBLOCK), and proc_open() pipes instead spin in
 * php_stdiop_read(): PeekNamedPipe() + usleep(10), up to 3,200,000 times,
 * until data arrives (main/streams/plain_wrapper.c). usleep(10) is a waitable
 * timer that rounds up to the timer resolution, so one fread() on an empty
 * pipe can wait from ~1 hour to many hours.
 *
 * So while spc sits in fread() on an empty stdout, nobody drains stderr. Once
 * the child writes 4 KiB (the default pipe buffer) to stderr it blocks in
 * WriteFile, never writes stdout again, and the two wait on each other. The
 * reverse order deadlocks the same way. In the Windows SDK build this fires
 * in `jom.exe /j8 install_dev` for openssl: the log stops right after the two
 * util\mkinstallvars.pl lines, jom sits at 0% CPU with no children, and the
 * job is cancelled at its 119-minute timeout. Every Windows build that got
 * past the download step since rc19 hung there.
 *
 * The patch merges the child's stderr into its stdout pipe (proc_open
 * descriptor ['redirect', 1]) so there is only one pipe to drain, and gives the
 * loop an always-empty php://memory stream in place of the stderr pipe so the
 * rest of passthru() is untouched. Captured output already included stderr
 * (the loop appended both pipes), so callers see the same text, now in the
 * order the child wrote it. Unix is unchanged: it uses stream_select(), which
 * works there.
 *
 * The input is pinned by sha256 to the release the needles were written
 * against. Bumping SPC_VERSION fails here loudly instead of running an
 * unpatched (or mis-patched) spc; drop this step once the fork ships the fix.
 */

declare(strict_types=1);

const PINNED_SHA256 = [
    // luthermonson/static-php-cli v3.0.0-pgo-rc20 spc-windows-x64.exe
    'v3.0.0-pgo-rc20' => '7ec62fe3451c615f9dcdbca5fd1e3287b27825d1c2a3d11e5fedadfdf5cfe32b',
];
const SHELL_PHP = 'src/StaticPHP/Runtime/Shell/Shell.php';
const MARKER = 'php-sdk: stderr merged into stdout on Windows';

function fail(string $msg): never
{
    fwrite(STDERR, "::error::patch-spc-passthru: {$msg}\n");
    exit(1);
}

if ($argc !== 3) {
    fail('usage: php -d phar.readonly=0 patch-spc-passthru.php <spc-windows-x64.exe> <out.exe>');
}
[, $in, $out] = $argv;
if (ini_get('phar.readonly')) {
    fail('run with -d phar.readonly=0');
}

$bin = file_get_contents($in);
if ($bin === false) {
    fail("cannot read {$in}");
}
$sha = hash('sha256', $bin);
$version = array_search($sha, PINNED_SHA256, true);
if ($version === false) {
    fail("{$in} has sha256 {$sha}, which is not a pinned spc release. The patch needles were written against "
        . implode(', ', array_keys(PINNED_SHA256)) . '. Re-check Shell::passthru() in the new release '
        . '(drop this step if the fork fixed it) before adding its hash.');
}
echo "==> {$in}: spc {$version} (sha256 {$sha})\n";

// spc-windows-x64.exe = phpmicro sfx (with its ini block) + a phar whose stub
// starts with a shebang line. Split at the shebang that precedes the stub's
// __HALT_COMPILER().
$halt = strrpos($bin, "__HALT_COMPILER();");
$off = $halt === false ? false : strrpos(substr($bin, 0, $halt), "#!/usr/bin/env php\n");
if ($off === false) {
    fail('could not locate the embedded phar');
}

$work = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'spc-patch-' . getmypid();
@mkdir($work);
$pharPath = $work . DIRECTORY_SEPARATOR . 'spc.phar';
file_put_contents($pharPath, substr($bin, $off));

$phar = new Phar($pharPath);
$src = file_get_contents("phar://{$pharPath}/" . SHELL_PHP);
if ($src === false) {
    fail('Shell.php not found in the phar');
}
if (str_contains($src, MARKER)) {
    fail('input is already patched');
}

$edits = [
    [
        "            2 => ['pipe', 'w'], // stderr\n",
        "            // " . MARKER . " (see php-sdk tools/spc-windows/patch-spc-passthru.php):\n"
        . "            // two anonymous pipes polled in turn deadlock on Windows.\n"
        . "            2 => \$is_windows ? ['redirect', 1] : ['pipe', 'w'], // stderr\n",
    ],
    [
        "options: PHP_OS_FAMILY === 'Windows' ? ['create_process_group' => true] : null);\n",
        "options: PHP_OS_FAMILY === 'Windows' ? ['create_process_group' => true] : null);\n"
        . "        if (\$is_windows && is_resource(\$process)) {\n"
        . "            // stderr arrives on \$pipes[1]; an always-empty stream stands in for it.\n"
        . "            \$pipes[2] = fopen('php://memory', 'rb');\n"
        . "        }\n",
    ],
];
foreach ($edits as [$needle, $replacement]) {
    $n = substr_count($src, $needle);
    if ($n !== 1) {
        fail("expected exactly 1 occurrence of " . json_encode($needle) . " in Shell.php, found {$n}");
    }
    $src = str_replace($needle, $replacement, $src);
}

$phar->startBuffering();
$phar[SHELL_PHP] = $src;
$phar[SHELL_PHP]->compress(Phar::GZ);
$phar->setSignatureAlgorithm(Phar::SHA512);
$phar->stopBuffering();
unset($phar);

$patched = substr($bin, 0, $off) . file_get_contents($pharPath);
if (file_put_contents($out, $patched) === false) {
    fail("cannot write {$out}");
}
@unlink($pharPath);
@rmdir($work);

// Read the result back through a fresh Phar handle: signature valid, edit present.
$check = $work . '-check.phar';
file_put_contents($check, substr($patched, $off));
$verify = file_get_contents("phar://{$check}/" . SHELL_PHP);
@unlink($check);
if ($verify === false || !str_contains($verify, MARKER) || !str_contains($verify, "['redirect', 1]")) {
    fail('patched phar does not read back with the edit');
}
echo "==> wrote {$out} (sha256 " . hash_file('sha256', $out) . ")\n";

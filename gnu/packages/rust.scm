;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2016 David Craven <david@craven.ch>
;;; Copyright © 2016 Eric Le Bihan <eric.le.bihan.dev@free.fr>
;;; Copyright © 2016 ng0 <ng0@n0.is>
;;; Copyright © 2017 Ben Woodcroft <donttrustben@gmail.com>
;;; Copyright © 2017, 2018 Nikolai Merinov <nikolai.merinov@member.fsf.org>
;;; Copyright © 2017 Efraim Flashner <efraim@flashner.co.il>
;;; Copyright © 2018, 2019 Tobias Geerinckx-Rice <me@tobias.gr>
;;; Copyright © 2018 Danny Milosavljevic <dannym+a@scratchpost.org>
;;; Copyright © 2019 Ivan Petkov <ivanppetkov@gmail.com>
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software; you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation; either version 3 of the License, or (at
;;; your option) any later version.
;;;
;;; GNU Guix is distributed in the hope that it will be useful, but
;;; WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with GNU Guix.  If not, see <http://www.gnu.org/licenses/>.

(define-module (gnu packages rust)
  #:use-module (gnu packages base)
  #:use-module (gnu packages bison)
  #:use-module (gnu packages bootstrap)
  #:use-module (gnu packages cmake)
  #:use-module (gnu packages compression)
  #:use-module (gnu packages curl)
  #:use-module (gnu packages elf)
  #:use-module (gnu packages flex)
  #:use-module (gnu packages gcc)
  #:use-module (gnu packages gdb)
  #:use-module (gnu packages jemalloc)
  #:use-module (gnu packages linux)
  #:use-module (gnu packages llvm)
  #:use-module (gnu packages pkg-config)
  #:use-module (gnu packages python)
  #:use-module (gnu packages ssh)
  #:use-module (gnu packages tls)
  #:use-module (gnu packages)
  #:use-module (guix build-system cargo)
  #:use-module (guix build-system gnu)
  #:use-module (guix build-system trivial)
  #:use-module (guix download)
  #:use-module (guix git-download)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix packages)
  #:use-module ((guix build utils) #:select (alist-replace))
  #:use-module (guix utils)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-26))

(define %cargo-reference-hash
  "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")

(define* (nix-system->gnu-triplet-for-rust
          #:optional (system (%current-system)))
  (match system
    ("x86_64-linux"   "x86_64-unknown-linux-gnu")
    ("i686-linux"     "i686-unknown-linux-gnu")
    ("armhf-linux"    "armv7-unknown-linux-gnueabihf")
    ("aarch64-linux"  "aarch64-unknown-linux-gnu")
    ("mips64el-linux" "mips64el-unknown-linux-gnuabi64")
    (_                (nix-system->gnu-triplet system))))

(define* (rust-uri version #:key (dist "static"))
  (string-append "https://" dist ".rust-lang.org/dist/"
                 "rustc-" version "-src.tar.gz"))

(define* (rust-bootstrapped-package base-rust version checksum)
  "Bootstrap rust VERSION with source checksum CHECKSUM using BASE-RUST."
  (package
    (inherit base-rust)
    (version version)
    (source
      (origin
        (inherit (package-source base-rust))
        (uri (rust-uri version))
        (sha256 (base32 checksum))))
    (native-inputs
     (alist-replace "cargo-bootstrap" (list base-rust "cargo")
                    (alist-replace "rustc-bootstrap" (list base-rust)
                                   (package-native-inputs base-rust))))))

(define-public mrustc
  (let ((rustc-version "1.29.0"))
    (package
      (name "mrustc")
      (version "0.9")
      (source (origin
                (method git-fetch)
                (uri (git-reference
                      (url "https://github.com/thepowersgang/mrustc.git")
                      (commit (string-append "v" version))))
                (file-name (git-file-name name version))
                (sha256
                 (base32
                  "194ny7vsks5ygiw7d8yxjmp1qwigd71ilchis6xjl6bb2sj97rd2"))))
      (outputs '("out" "cargo"))
      (build-system gnu-build-system)
      (inputs
       `(("llvm" ,llvm-3.9.1)))
      (native-inputs
       `(("bison" ,bison)
         ("flex" ,flex)
         ;; Required for the libstd sources.
         ("rustc" ,(package-source rust-1.29))))
      (arguments
       `(#:test-target "local_tests"
         #:make-flags (list (string-append "LLVM_CONFIG="
                                           (assoc-ref %build-inputs "llvm")
                                           "/bin/llvm-config"))
         #:phases
         (modify-phases %standard-phases
          (add-after 'unpack 'patch-date
            (lambda _
              (substitute* "Makefile"
               (("shell date") "shell date -d @1"))
              #t))
           (add-after 'patch-date 'unpack-target-compiler
             (lambda* (#:key inputs outputs #:allow-other-keys)
               (substitute* "minicargo.mk"
                 ;; Don't try to build LLVM.
                 (("^[$][(]LLVM_CONFIG[)]:") "xxx:")
                 ;; Build for the correct target architecture.
                 (("^RUSTC_TARGET := x86_64-unknown-linux-gnu")
                  (string-append "RUSTC_TARGET := "
                                 ,(or (%current-target-system)
                                      (nix-system->gnu-triplet-for-rust)))))
               (invoke "tar" "xf" (assoc-ref inputs "rustc"))
               (chdir "rustc-1.29.0-src")
               (invoke "patch" "-p0" "../rustc-1.29.0-src.patch")
               (chdir "..")
               #t))
           (replace 'configure
             (lambda* (#:key inputs #:allow-other-keys)
               (setenv "CC" (string-append (assoc-ref inputs "gcc") "/bin/gcc"))
               #t))
           (add-after 'build 'build-minicargo
             (lambda _
               (for-each (lambda (target)
                           (invoke "make" "-f" "minicargo.mk" target))
                         '("output/libstd.rlib" "output/libpanic_unwind.rlib"
                           "output/libproc_macro.rlib" "output/libtest.rlib"))
               ;; Technically the above already does it - but we want to be clear.
               (invoke "make" "-C" "tools/minicargo")))
           (replace 'install
             (lambda* (#:key inputs outputs #:allow-other-keys)
               (let* ((out (assoc-ref outputs "out"))
                      (bin (string-append out "/bin"))
                      (tools-bin (string-append out "/tools/bin"))
                      (cargo-out (assoc-ref outputs "cargo"))
                      (cargo-bin (string-append cargo-out "/bin"))
                      (lib (string-append out "/lib"))
                      (lib/rust (string-append lib "/mrust"))
                      (gcc (assoc-ref inputs "gcc")))
                 ;; These files are not reproducible.
                 (for-each delete-file (find-files "output" "\\.txt$"))
                 (delete-file-recursively "output/local_tests")
                 (mkdir-p lib)
                 (copy-recursively "output" lib/rust)
                 (mkdir-p bin)
                 (mkdir-p tools-bin)
                 (install-file "bin/mrustc" bin)
                 ;; minicargo uses relative paths to resolve mrustc.
                 (install-file "tools/bin/minicargo" tools-bin)
                 (install-file "tools/bin/minicargo" cargo-bin)
                 #t))))))
      (synopsis "Compiler for the Rust progamming language")
      (description "Rust is a systems programming language that provides memory
safety and thread safety guarantees.")
      (home-page "https://github.com/thepowersgang/mrustc")
      ;; Dual licensed.
      (license (list license:asl2.0 license:expat)))))

(define rust-1.29
  (package
    (name "rust")
    (version "1.29.0")
    (source
      (origin
        (method url-fetch)
        (uri (rust-uri "1.29.0"))
        (sha256 (base32 "1sb15znckj8pc8q3g7cq03pijnida6cg64yqmgiayxkzskzk9sx4"))
        (modules '((guix build utils)))
        (snippet '(begin (delete-file-recursively "src/llvm") #t))
        (patches (map search-patch '("rust-1.25-accept-more-detailed-gdb-lines.patch"
                                     "rust-reproducible-builds.patch"
                                     "rustc-1.29.0-src.patch")))))
    (outputs '("out" "cargo" "doc"))
    (properties '((timeout . 72000)               ;20 hours
                  (max-silent-time . 18000)))     ;5 hours (for armel)
    (arguments
     `(#:imported-modules ,%cargo-utils-modules ;for `generate-checksums'
       #:modules ((guix build utils) (ice-9 match) (guix build gnu-build-system))
       #:phases
       (modify-phases %standard-phases
         (add-after 'unpack 'set-env
           (lambda* (#:key inputs #:allow-other-keys)
             ;; Disable test for cross compilation support.
(write "X")
             (setenv "CFG_DISABLE_CROSS_TESTS" "1")
             (setenv "SHELL" (which "sh"))
             (setenv "CONFIG_SHELL" (which "sh"))
             (setenv "CC" (string-append (assoc-ref inputs "gcc") "/bin/gcc"))
             ;; guix llvm-3.9.1 package installs only shared libraries
             (setenv "LLVM_LINK_SHARED" "1")
             #t))
         (add-after 'unpack 'patch-tests
           (lambda* (#:key inputs #:allow-other-keys)
             (let ((bash (assoc-ref inputs "bash")))
               (substitute* "src/libstd/process.rs"
                 ;; The newline is intentional.
                 ;; There's a line length "tidy" check in Rust which would
                 ;; fail otherwise.
                 (("\"/bin/sh\"") (string-append "\n\"" bash "/bin/sh\"")))
               (substitute* "src/libstd/net/tcp.rs"
                 ;; There is no network in build environment
                 (("fn connect_timeout_unroutable")
                  "#[ignore]\nfn connect_timeout_unroutable"))
               ;; <https://lists.gnu.org/archive/html/guix-devel/2017-06/msg00222.html>
               (substitute* "src/libstd/sys/unix/process/process_common.rs"
                (("fn test_process_mask") "#[allow(unused_attributes)]
    #[ignore]
    fn test_process_mask"))
               #t)))
         (add-after 'patch-tests 'patch-cargo-index-update
           (lambda* _
             (substitute* "src/tools/cargo/tests/testsuite/generate_lockfile.rs"
               ;; This test wants to update the crate index.
               (("fn no_index_update") "#[ignore]\nfn no_index_update"))
             #t))
         (add-after 'patch-tests 'patch-aarch64-test
           (lambda* _
             (substitute* "src/librustc_metadata/dynamic_lib.rs"
               ;; This test is known to fail on aarch64 and powerpc64le:
               ;; https://github.com/rust-lang/rust/issues/45410
               (("fn test_loading_cosine") "#[ignore]\nfn test_loading_cosine"))
             ;; This test fails on aarch64 with llvm@6.0:
             ;; https://github.com/rust-lang/rust/issues/49807
             ;; other possible solution:
             ;; https://github.com/rust-lang/rust/pull/47688
             (delete-file "src/test/debuginfo/by-value-self-argument-in-trait-impl.rs")
             #t))
         (add-after 'patch-tests 'remove-unsupported-tests
           (lambda* _
             ;; Our ld-wrapper cannot process non-UTF8 bytes in LIBRARY_PATH.
             ;; <https://lists.gnu.org/archive/html/guix-devel/2017-06/msg00193.html>
             (delete-file-recursively "src/test/run-make-fulldeps/linker-output-non-utf8")
             #t))
         (add-after 'patch-source-shebangs 'patch-cargo-checksums
           (lambda* _
             (substitute* "src/Cargo.lock"
               (("(\"checksum .* = )\".*\"" all name)
                (string-append name "\"" ,%cargo-reference-hash "\"")))
             (for-each
              (lambda (filename)
                (use-modules (guix build cargo-utils))
                (delete-file filename)
                (let* ((dir (dirname filename)))
                  (display (string-append
                            "patch-cargo-checksums: generate-checksums for "
                            dir "\n"))
                  (generate-checksums dir)))
              (find-files "src/vendor" ".cargo-checksum.json"))
             #t))
         ;; This phase is overridden by newer versions.
         (replace 'configure
           (lambda* (#:key inputs outputs #:allow-other-keys)
             (setenv "CXX" "g++")
             (setenv "HOST_CXX" "g++")
             #t))
         ;; This phase is overridden by newer versions.
         (replace 'build
           (lambda* (#:key inputs outputs #:allow-other-keys)
             (let ((rustc-bootstrap (assoc-ref inputs "rustc-bootstrap")))
;(invoke "ls" "src/vendor/getopts")
;(newline)
               (setenv "CFG_COMPILER_HOST_TRIPLE"
                ,(nix-system->gnu-triplet (%current-system)))
               (setenv "CFG_RELEASE" "")
               (setenv "CFG_RELEASE_CHANNEL" "stable")
               (setenv "CFG_LIBDIR_RELATIVE" "lib")
               (setenv "CFG_VERSION" "1.29.0-stable-mrustc")
               ; bad: (setenv "CFG_PREFIX" "mrustc") ; FIXME output path.
               ;; Crate::load_extern_crate ignores the search path, so make
               ;; the situation easier for it.
               (copy-recursively (string-append rustc-bootstrap "/lib/mrust")
                                 "output")
               ;(mkdir-p "output")
               (invoke (string-append rustc-bootstrap "/tools/bin/minicargo")
                       "src/rustc" "--vendor-dir" "src/vendor"
                       "--output-dir" "output/rustc-build"
                       "-L" (string-append rustc-bootstrap "/lib/mrust")
                       "-j" "1")
               (setenv "CFG_COMPILER_HOST_TRIPLE" #f)
               (setenv "CFG_RELEASE" #f)
               (setenv "CFG_RELEASE_CHANNEL" #f)
               (setenv "CFG_VERSION" #f)
               (setenv "CFG_PREFIX" #f)
               (setenv "CFG_LIBDIR_RELATIVE" #f)
               (invoke (string-append rustc-bootstrap "/tools/bin/minicargo")
                       "src/tools/cargo" "--vendor-dir" "src/vendor"
                       "--output-dir" "output/cargo-build"
                       ;"-L" "output/"
                       "-L" (string-append rustc-bootstrap "/lib/mrust")
                       "-j" "1")
               ;; Now use the newly-built rustc to build the libraries.
               ;; One day that could be replaced by:
               ;; (invoke "output/cargo-build/cargo" "build"
               ;;         "--manifest-path" "src/bootstrap/Cargo.toml"
               ;;         "--verbose") ; "--locked" "--frozen"
               ;; but right now, Cargo has problems with libstd's circular
               ;; dependencies.
               (mkdir-p "output/target-libs")
               (for-each (match-lambda
                          ((name . flags)
                            (write name)
                            (newline)
                            (apply invoke
                                   "output/rustc-build/rustc"
                                   "-C" (string-append "linker="
                                                       (getenv "CC"))
                                   ;; Required for libterm.
                                   "-Z" "force-unstable-if-unmarked"
                                   "-L" "output/target-libs"
                                   (string-append "src/" name "/lib.rs")
                                   "-o"
                                   (string-append "output/target-libs/"
                                                  (car (string-split name #\/))
                                                  ".rlib")
                                   flags)))
                         '(("libcore")
                           ("libstd_unicode")
                           ("liballoc")
                           ("libcollections")
                           ("librand")
                           ("liblibc/src" "--cfg" "stdbuild")
                           ("libunwind" "-l" "gcc_s")
                           ("libcompiler_builtins")
                           ("liballoc_system")
                           ("libpanic_unwind")
                           ;; Uses "cc" to link.
                           ("libstd" "-l" "dl" "-l" "rt" "-l" "pthread")
                           ("libarena")

                           ;; Test dependencies:

                           ("libgetopts")
                           ("libterm")
                           ("libtest")))
               #t)))
         ;; This phase is overridden by newer versions.
         (replace 'check
           (const #t))
         ;; This phase is overridden by newer versions.
         (replace 'install
           (lambda* (#:key inputs outputs #:allow-other-keys)
             (let* ((out (assoc-ref outputs "out"))
                    (target-system ,(or (%current-target-system)
                                        (nix-system->gnu-triplet
                                         (%current-system))))
                    (out-libs (string-append out "/lib/rustlib/"
                                             target-system "/lib")))
                                        ;(setenv "CFG_PREFIX" out)
               (mkdir-p out-libs)
               (copy-recursively "output/target-libs" out-libs)
               (install-file "output/rustc-build/rustc"
                             (string-append out "/bin"))
               (install-file "output/rustc-build/rustdoc"
                             (string-append out "/bin"))
               (install-file "output/cargo-build/cargo"
                             (string-append (assoc-ref outputs "cargo")
                                            "/bin")))
             #t)))))
    (build-system gnu-build-system)
    (native-inputs
     `(("bison" ,bison) ; For the tests
       ("cmake" ,cmake-minimal)
       ("flex" ,flex) ; For the tests
       ("gdb" ,gdb)   ; For the tests
       ("procps" ,procps) ; For the tests
       ("python-2" ,python-2)
       ("rustc-bootstrap" ,mrustc)
       ("cargo-bootstrap" ,mrustc "cargo")
       ("pkg-config" ,pkg-config) ; For "cargo"
       ("which" ,which)))
    (inputs
     `(("jemalloc" ,jemalloc-4.5.0)
       ("llvm" ,llvm-6)
       ("openssl" ,openssl-1.0)
       ("libssh2" ,libssh2) ; For "cargo"
       ("libcurl" ,curl)))  ; For "cargo"

    ;; rustc invokes gcc, so we need to set its search paths accordingly.
    ;; Note: duplicate its value here to cope with circular dependencies among
    ;; modules (see <https://bugs.gnu.org/31392>).
    (native-search-paths
     (list (search-path-specification
            (variable "CPATH")
            (files '("include")))
           (search-path-specification
            (variable "LIBRARY_PATH")
            (files '("lib" "lib64")))))

    (synopsis "Compiler for the Rust progamming language")
    (description "Rust is a systems programming language that provides memory
safety and thread safety guarantees.")
    (home-page "https://www.rust-lang.org")
    ;; Dual licensed.
    (license (list license:asl2.0 license:expat))))

(define-public rust-1.30
  (let ((base-rust
         (rust-bootstrapped-package rust-1.29 "1.30.1"
          "0aavdc1lqv0cjzbqwl5n59yd0bqdlhn0zas61ljf38yrvc18k8rn")))
    (package
      (inherit base-rust)
      (source
        (origin
          (inherit (package-source base-rust))
          (snippet '(begin
                      (delete-file-recursively "src/jemalloc")
                      (delete-file-recursively "src/llvm")
                      (delete-file-recursively "src/llvm-emscripten")
                      (delete-file-recursively "src/tools/clang")
                      (delete-file-recursively "src/tools/lldb")
                      #t))
          (patches '())))
      (outputs '("out" "doc" "cargo"))
      ;; Since rust-2.19 is local, it's quite probable that Hydra
      ;; will build rust-1.29 only as a dependency of rust-1.20.
      ;; But then Hydra will use the wrong properties, the ones here,
      ;; for rust-1.29.  Therefore, we copied the properties of
      ;; rust-1.29 here.
      (properties '((timeout . 72000)               ;20 hours
                    (max-silent-time . 18000)))     ;5 hours (for armel)
      (inputs
       ;; Use LLVM 6.0
       (alist-replace "llvm" (list llvm-6)
                      (package-inputs base-rust)))
      (arguments
       (substitute-keyword-arguments (package-arguments rust-1.29)
         ((#:phases phases)
          `(modify-phases ,phases
             (add-after 'unpack 'remove-flaky-test
               (lambda _
                 ;; See <https://github.com/rust-lang/rust/issues/43402>.
                 (when (file-exists? "src/test/run-make/issue-26092")
                   (delete-file-recursively "src/test/run-make/issue-26092"))
                 #t))
             (add-after 'configure 'enable-codegen-tests
               ;; Codegen tests should pass with llvm 6, so enable them.
               (lambda* _
                 (substitute* "config.toml"
                   (("codegen-tests = false") ""))
                 #t))
              ;; The test has been moved elsewhere.
              (add-after 'patch-tests 'disable-amd64-avx-test
                (lambda _
                  (substitute* "src/test/ui/issues/issue-44056.rs"
                   (("only-x86_64") "ignore-test"))
                  #t))
             (add-after 'patch-tests 'patch-cargo-tests
               (lambda _
                 (substitute* "src/tools/cargo/tests/build.rs"
                  (("/usr/bin/env") (which "env"))
                  ;; Guix llvm is compiled without asmjs-unknown-emscripten.
                  (("fn wasm32_final_outputs") "#[ignore]\nfn wasm32_final_outputs"))
                 (substitute* "src/tools/cargo/tests/death.rs"
                  ;; This is stuck when built in container.
                  (("fn ctrl_c_kills_everyone") "#[ignore]\nfn ctrl_c_kills_everyone"))
                 ;; Prints test output in the wrong order when built on
                 ;; i686-linux.
                 (substitute* "src/tools/cargo/tests/test.rs"
                   (("fn cargo_test_env") "#[ignore]\nfn cargo_test_env"))

                 ;; These tests pull in a dependency on "git", which changes
                 ;; too frequently take part in the Rust toolchain.
                 (substitute* "src/tools/cargo/tests/new.rs"
                   (("fn author_prefers_cargo") "#[ignore]\nfn author_prefers_cargo")
                   (("fn finds_author_git") "#[ignore]\nfn finds_author_git")
                   (("fn finds_local_author_git") "#[ignore]\nfn finds_local_author_git"))
                 #t))
             (add-after 'patch-cargo-tests 'patch-cargo-env-shebang
               (lambda* (#:key inputs #:allow-other-keys)
                 (let ((coreutils (assoc-ref inputs "coreutils")))
                   (substitute* "src/tools/cargo/tests/testsuite/fix.rs"
                     ;; Cargo has a test which explicitly sets a
                     ;; RUSTC_WRAPPER environment variable which points
                     ;; to /usr/bin/env. Since it's not a shebang, it
                     ;; needs to be manually patched
                     (("\"/usr/bin/env\"")
                      (string-append "\"" coreutils "/bin/env\"")))
                   #t)))
             (add-after 'patch-cargo-env-shebang 'ignore-cargo-package-tests
               (lambda* _
                 (substitute* "src/tools/cargo/tests/testsuite/package.rs"
                   ;; These tests largely check that cargo outputs warning/error
                   ;; messages as expected. It seems that cargo outputs an
                   ;; absolute path to something in the store instead of the
                   ;; expected relative path (e.g. `[..]`) so we'll ignore
                   ;; these for now
                   (("fn include") "#[ignore]\nfn include")
                   (("fn exclude") "#[ignore]\nfn exclude"))
                   #t))

             (replace 'configure
               (lambda* (#:key inputs outputs #:allow-other-keys)
                 (let* ((out (assoc-ref outputs "out"))
                        (doc (assoc-ref outputs "doc"))
                        (gcc (assoc-ref inputs "gcc"))
                        (gdb (assoc-ref inputs "gdb"))
                        (binutils (assoc-ref inputs "binutils"))
                        (python (assoc-ref inputs "python-2"))
                        (rustc (assoc-ref inputs "rustc-bootstrap"))
                        (cargo (assoc-ref inputs "cargo-bootstrap"))
                        (llvm (assoc-ref inputs "llvm"))
                        (jemalloc (assoc-ref inputs "jemalloc")))
                   (call-with-output-file "config.toml"
                     (lambda (port)
                       (display (string-append "
[llvm]
[build]
cargo = \"" cargo "/bin/cargo" "\"
rustc = \"" rustc "/bin/rustc" "\"
docs = true
python = \"" python "/bin/python2" "\"
gdb = \"" gdb "/bin/gdb" "\"
vendor = true
submodules = false
[install]
prefix = \"" out "\"
docdir = \"" doc "/share/doc/rust" "\"
sysconfdir = \"etc\"
[rust]
default-linker = \"" gcc "/bin/gcc" "\"
channel = \"stable\"
rpath = true
" ;; There are 2 failed codegen tests:
;; codegen/mainsubprogram.rs and codegen/mainsubprogramstart.rs
;; These tests require a patched LLVM
"codegen-tests = false
[target." ,(nix-system->gnu-triplet-for-rust) "]
llvm-config = \"" llvm "/bin/llvm-config" "\"
cc = \"" gcc "/bin/gcc" "\"
cxx = \"" gcc "/bin/g++" "\"
ar = \"" binutils "/bin/ar" "\"
jemalloc = \"" jemalloc "/lib/libjemalloc_pic.a" "\"
[dist]
") port)))
                   #t)))
             (add-after 'configure 'provide-cc
               (lambda* (#:key inputs #:allow-other-keys)
                 (symlink (string-append (assoc-ref inputs "gcc") "/bin/gcc")
                          "/tmp/cc")
                 (setenv "PATH" (string-append "/tmp:" (getenv "PATH")))
                 #t))
             (delete 'patch-cargo-tomls)
             (add-before 'build 'reset-timestamps-after-changes
               (lambda* _
                 (for-each
                  (lambda (filename)
                    ;; Rust 1.20.0 treats timestamp 0 as "file doesn't exist".
                    ;; Therefore, use timestamp 1.
                    (utime filename 1 1 1 1))
                  (find-files "." #:directories? #t))
                 #t))
             (replace 'build
               (lambda* _
                 (invoke "./x.py" "build")
                 (invoke "./x.py" "build" "src/tools/cargo")))
             (replace 'check
               (lambda* _
                 ;; Enable parallel execution.
                 (let ((parallel-job-spec
                        (string-append "-j" (number->string
                                             (min 4
                                                  (parallel-job-count))))))
                   (invoke "./x.py" parallel-job-spec "test" "-vv")
                   (invoke "./x.py" parallel-job-spec "test"
                           "src/tools/cargo"))))
             (replace 'install
               (lambda* (#:key outputs #:allow-other-keys)
                 (invoke "./x.py" "install")
                 (substitute* "config.toml"
                   ;; replace prefix to specific output
                   (("prefix = \"[^\"]*\"")
                    (string-append "prefix = \"" (assoc-ref outputs "cargo") "\"")))
                 (invoke "./x.py" "install" "cargo")))
             (add-after 'install 'delete-install-logs
               (lambda* (#:key outputs #:allow-other-keys)
                 (define (delete-manifest-file out-path file)
                   (delete-file (string-append out-path "/lib/rustlib/" file)))

                 (let ((out (assoc-ref outputs "out"))
                       (cargo-out (assoc-ref outputs "cargo")))
                   (for-each
                     (lambda (file) (delete-manifest-file out file))
                     '("install.log"
                       "manifest-rust-docs"
                       "manifest-rust-std-x86_64-unknown-linux-gnu"
                       "manifest-rustc"))
                   (for-each
                     (lambda (file) (delete-manifest-file cargo-out file))
                     '("install.log"
                       "manifest-cargo"))
                   #t)))
             (add-after 'install 'wrap-rustc
               (lambda* (#:key inputs outputs #:allow-other-keys)
                 (let ((out (assoc-ref outputs "out"))
                       (libc (assoc-ref inputs "libc"))
                       (ld-wrapper (assoc-ref inputs "ld-wrapper")))
                   ;; Let gcc find ld and libc startup files.
                   (wrap-program (string-append out "/bin/rustc")
                     `("PATH" ":" prefix (,(string-append ld-wrapper "/bin")))
                     `("LIBRARY_PATH" ":" suffix (,(string-append libc "/lib"))))
                   #t))))))))))

(define-public rust-1.31
  (let ((base-rust
         (rust-bootstrapped-package rust-1.30 "1.31.1"
          "0sk84ff0cklybcp0jbbxcw7lk7mrm6kb6km5nzd6m64dy0igrlli")))
    (package
      (inherit base-rust)
      (arguments
       (substitute-keyword-arguments (package-arguments base-rust)
         ((#:phases phases)
          `(modify-phases ,phases
             (add-after 'patch-tests 'patch-command-exec-tests
               (lambda* (#:key inputs #:allow-other-keys)
                 (let ((coreutils (assoc-ref inputs "coreutils")))
                   (substitute* "src/test/run-pass/command-exec.rs"
                     ;; This test suite includes some tests that the stdlib's
                     ;; `Command` execution properly handles situations where
                     ;; the environment or PATH variable are empty, but this
                     ;; fails since we don't have `echo` available in the usual
                     ;; Linux directories.
                     ;; NB: the leading space is so we don't fail a tidy check
                     ;; for trailing whitespace, and the newlines are to ensure
                     ;; we don't exceed the 100 chars tidy check as well
                     ((" Command::new\\(\"echo\"\\)")
                      (string-append "\nCommand::new(\"" coreutils "/bin/echo\")\n")))
                   #t)))
	     ;; The test has been moved elsewhere.
             (replace 'disable-amd64-avx-test
               (lambda _
                 (substitute* "src/test/ui/issues/issue-44056.rs"
                   (("only-x86_64") "ignore-test"))
                  #t))
             (add-after 'patch-tests 'patch-process-docs-rev-cmd
               (lambda* _
                 ;; Disable some doc tests which depend on the "rev" command
                 ;; https://github.com/rust-lang/rust/pull/58746
                 (substitute* "src/libstd/process.rs"
                   (("```rust") "```rust,no_run"))
                 #t)))))))))

(define-public rust-1.32
  (let ((base-rust
         (rust-bootstrapped-package rust-1.31 "1.32.0"
          "0ji2l9xv53y27xy72qagggvq47gayr5lcv2jwvmfirx029vlqnac")))
    (package
      (inherit base-rust)
      (source
        (origin
          (inherit (package-source base-rust))
          (snippet '(begin (delete-file-recursively "src/llvm")
                           (delete-file-recursively "src/llvm-emscripten")
                           (delete-file-recursively "src/tools/clang")
                           (delete-file-recursively "src/tools/lldb")
                           (delete-file-recursively "vendor/jemalloc-sys/jemalloc")
                           #t))
          (patches (map search-patch '("rust-reproducible-builds.patch")))
          ;; the vendor directory has moved to the root of
          ;; the tarball, so we have to strip an extra prefix
          (patch-flags '("-p2"))))
      (inputs
       ;; Downgrade to LLVM 6, all LTO tests appear to fail with LLVM 7.0.1
       (alist-replace "llvm" (list llvm-6)
                      (package-inputs base-rust)))
      (arguments
       (substitute-keyword-arguments (package-arguments base-rust)
         ((#:phases phases)
          `(modify-phases ,phases
             ;; Cargo.lock and the vendor/ directory have been moved to the
             ;; root of the rust tarball
             (replace 'patch-cargo-checksums
               (lambda* _
                 (substitute* "Cargo.lock"
                   (("(\"checksum .* = )\".*\"" all name)
                    (string-append name "\"" ,%cargo-reference-hash "\"")))
                 (for-each
                  (lambda (filename)
                    (use-modules (guix build cargo-utils))
                    (delete-file filename)
                    (let* ((dir (dirname filename)))
                      (display (string-append
                                "patch-cargo-checksums: generate-checksums for "
                                dir "\n"))
                      (generate-checksums dir)))
                  (find-files "vendor" ".cargo-checksum.json"))
                 #t))
             (add-after 'enable-codegen-tests 'override-jemalloc
               (lambda* (#:key inputs #:allow-other-keys)
                 ;; The compiler is no longer directly built against jemalloc,
                 ;; but rather via the jemalloc-sys crate (which vendors the
                 ;; jemalloc source). To use jemalloc we must enable linking to
                 ;; it (otherwise it would use the system allocator), and set
                 ;; an environment variable pointing to the compiled jemalloc.
                 (substitute* "config.toml"
                   (("^jemalloc =.*$") "")
                   (("[[]rust[]]") "\n[rust]\njemalloc=true\n"))
                 (setenv "JEMALLOC_OVERRIDE" (string-append (assoc-ref inputs "jemalloc")
                                                            "/lib/libjemalloc_pic.a"))
                 #t))
             ;; Remove no longer relevant steps
             (delete 'remove-flaky-test)
             (delete 'patch-aarch64-test))))))))

(define-public rust-1.33
  (let ((base-rust
         (rust-bootstrapped-package rust-1.32 "1.33.0"
           "152x91mg7bz4ygligwjb05fgm1blwy2i70s2j03zc9jiwvbsh0as")))
    (package
      (inherit base-rust)
      (source
        (origin
          (inherit (package-source base-rust))
          (patches '())
          (patch-flags '("-p1"))))
      (inputs
       ;; Upgrade to jemalloc@5.1.0
       (alist-replace "jemalloc" (list jemalloc)
                      (package-inputs base-rust)))
      (arguments
       (substitute-keyword-arguments (package-arguments base-rust)
         ((#:phases phases)
          `(modify-phases ,phases
             (delete 'ignore-cargo-package-tests)
             (add-after 'configure 'configure-test-threads
               ;; Several rustc and cargo tests will fail if run on one core
               ;; https://github.com/rust-lang/rust/issues/59122
               ;; https://github.com/rust-lang/cargo/issues/6746
               ;; https://github.com/rust-lang/rust/issues/58907
               (lambda* (#:key inputs #:allow-other-keys)
                 (setenv "RUST_TEST_THREADS" "2")
                 #t)))))))))

(define-public rust-1.34
  (let ((base-rust
         (rust-bootstrapped-package rust-1.33 "1.34.1"
           "19s09k7y5j6g3y4d2rk6kg9pvq6ml94c49w6b72dmq8p9lk8bixh")))
    (package
      (inherit base-rust)
      (source
        (origin
          (inherit (package-source base-rust))
          (snippet '(begin
                      (delete-file-recursively "src/llvm-emscripten")
                      (delete-file-recursively "src/llvm-project")
                      (delete-file-recursively "vendor/jemalloc-sys/jemalloc")
                      #t)))))))

(define-public rust-1.35
  (let ((base-rust
         (rust-bootstrapped-package rust-1.34 "1.35.0"
           "0bbizy6b7002v1rdhrxrf5gijclbyizdhkglhp81ib3bf5x66kas")))
    (package
      (inherit base-rust)
      (inputs
       (alist-replace "llvm" (list llvm-8)
                      (package-inputs base-rust)))
      (arguments
       (substitute-keyword-arguments (package-arguments base-rust)
         ((#:phases phases)
          `(modify-phases ,phases
             ;; The tidy test includes a pass which ensures large binaries
             ;; don't accidentally get checked into the rust git repo.
             ;; Unfortunately the test assumes that git is always available,
             ;; so we'll comment out the invocation of this pass.
             (add-after 'configure 'disable-tidy-bins-check
               (lambda* _
                 (substitute* "src/tools/tidy/src/main.rs"
                   (("bins::check") "//bins::check"))
                 #t)))))))))

(define-public rust-1.36
  (let ((base-rust
         (rust-bootstrapped-package rust-1.35 "1.36.0"
           "06xv2p6zq03lidr0yaf029ii8wnjjqa894nkmrm6s0rx47by9i04")))
    (package
      (inherit base-rust)
      (arguments
       (substitute-keyword-arguments (package-arguments base-rust)
         ((#:phases phases)
          `(modify-phases ,phases
             (delete 'patch-process-docs-rev-cmd))))))))

(define-public rust
  (let ((base-rust
         (rust-bootstrapped-package rust-1.36 "1.37.0"
           "1hrqprybhkhs6d9b5pjskfnc5z9v2l2gync7nb39qjb5s0h703hj")))
    (package
      (inherit base-rust)
      (arguments
       (substitute-keyword-arguments (package-arguments base-rust)
         ((#:phases phases)
          `(modify-phases ,phases
             (add-before 'configure 'configure-cargo-home
               (lambda _
                 (let ((cargo-home (string-append (getcwd) "/.cargo")))
                   (mkdir-p cargo-home)
                   (setenv "CARGO_HOME" cargo-home)
                   #t))))))))))

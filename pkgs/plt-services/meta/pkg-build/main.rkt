#lang racket/base
(require racket/cmdline
         racket/file
         racket/port
         racket/format
         racket/date
         racket/list
         racket/set
         racket/string
         racket/runtime-path
         net/url
         pkg/lib
         file/untgz
         distro-build/vbox
         web-server/servlet-env
         (only-in scribble/html a td tr #%top)
         "union-find.rkt"
         "thread.rkt"
         "ssh.rkt"
         "status.rkt"
         "summary.rkt")

(provide vbox-vm
         build-pkgs)

(define-runtime-path pkg-list-rkt "pkg-list.rkt")
(define-runtime-path pkg-adds-rkt "pkg-adds.rkt")

;; ----------------------------------------

;; Builds all packages from a given catalog and using a given snapshot.
;; The build of each package is isolated through a virtual machine,
;; and the result is both a set of built packages and a complete set
;; of documentation.
;;
;; To successfully build, a package must
;;   - install without error
;;   - correctly declare its dependencies (but may work, anyway,
;;     if build order happens to accomodate)
;;   - depend on packages that build successfully on their own
;;   - refer only to other packages in the snapshot and catalog
;;     (and, in particular, must not use PLaneT packages)
;;   - build without special system libraries (i.e., beyond the ones
;;     needed by `racket/draw`)
;;
;; A successful build not not require that its declaraed dependencies
;; are complete if the needed packages end up installed, anyway, but
;; the declaraed dependencies are checked.
;;
;; Even when a build is unsuccessful, any documentation that is built
;; along the way is extracted, if possible.
;;
;; To do:
;;  - salvage docs from conflicst & dumster
;;  - tier-based selection of packages on conflict
;;  - support for running tests

(struct vm remote (name init-snapshot installed-snapshot))

;; Each VM must provide at least an ssh server and `tar`, it must have
;; any system libraries installed that are needed for building
;; (typically the libraries needed by `racket/draw`), and the intent
;; is that it is otherwise isolated (e.g., no network connection
;; except to the host)
(define (vbox-vm
         ;; VirtualBox VM name:
         #:name name
         ;; IP address of VM (from host):
         #:host host
         ;; User for ssh login to VM:
         #:user [user "racket"]
         ;; Working directory on VM:
         #:dir [dir "/home/racket/build-pkgs"]
         ;; Name of a clean starting snapshot in the VM:
         #:init-shapshot [init-snapshot "init"]
         ;; An "installed" snapshot is created after installing Racket
         ;; and before building any package:
         #:installed-shapshot [installed-snapshot "installed"])
  (unless (complete-path? dir)
    (error 'vbox-vm "need a complete path for #:dir"))
  (vm host user dir name init-snapshot installed-snapshot))

(define (build-pkgs 
         ;; Besides a running Racket, the host machine must provide
         ;; `ssh`, `scp`, and `VBoxManage`.

         ;; All local state is here, where state from a previous
         ;; run is used to work incrementally:
         #:work-dir given-work-dir
         ;; Directory content:
         ;;
         ;;   "installer" --- directly holding installer downloaded
         ;;     from the snapshot site
         ;;
         ;;   "install-list.rktd" --- list of packages found in
         ;;     the installation
         ;;   "install-adds.rktd" --- table of docs, libs, etc.
         ;;     in the installation (to detect conflicts)
         ;;   "install-doc.tgz" --- copy of installation's docs
         ;;
         ;;   "server/archive" plus "state.sqlite" --- archived
         ;;     packages, taken from the snapshot site plus additional
         ;;     specified catalogs
         ;;
         ;;   "server/built" --- built packages
         ;;     For a package P:
         ;;      * "pkgs/P.orig-CHECKSUM" matching archived catalog
         ;;         + "pkgs/P.zip"
         ;;         + "P.zip.CHECKSUM"
         ;;        => up-to-date and successful,
         ;;           "docs/P-adds.rktd" listing of docs, exes, etc., and
         ;;           "success/P" records success;
         ;;           "install/P" records installation
         ;;           "deps/P" record dependency-checking failure;
         ;;      * pkgs/P.orig-CHECKSUM matching archived catalog
         ;;         + fail/P
         ;;        => up-to-date and failed;
         ;;           "install/P" may record installation success
         ;;
         ;;   "dumpster" --- saved builds of failed packages if the
         ;;     package at least installs; maybe the attempt built
         ;;     some documentation
         ;;
         ;;   "doc" --- unpacked docs with non-conflicting
         ;;     packages installed
         ;;   "all-doc.tgz" --- "doc", still packed
         ;;
         ;;   "summary.rktd" --- summary of build results, a hash
         ;;     table mapping each package name to another hash table
         ;;     with the following keys:
         ;;       'success-log --- #f or relative path
         ;;       'failure-log --- #f or relative path
         ;;       'dep-failure-log --- #f or relative path
         ;;       'docs --- list of one of
         ;;                  * (docs/none name)
         ;;                  * (docs/main name path)
         ;;       'conflict-log --- #f, relative path, or
         ;;                         (conflicts/indirect path)
         ;;   "index.html" (and "robots.txt", etc.) --- summary in
         ;;     web-page form
         ;;
         ;; A package is rebuilt if its checksum changes or if one of
         ;; its declared dependencies changes.

         ;; URL to provide the installer and pre-built packages:
         #:snapshot-url snapshot-url
         ;; Name of platform for installer to get from snapshot:
         #:installer-platform-name installer-platform-name

         ;; VirtualBox VMs (created by `vbox-vm`), at least one:
         #:vms vms

         ;; Skip the install step if the "installed" snapshot is
         ;; ready and "install-list.rktd" is up-to-date:
         #:skip-install? [skip-install? #f]
         
         ;; Catalogs of packages to build (via an archive):
         #:pkg-catalogs [pkg-catalogs (list "http://pkgs.racket-lang.org/")]
         ;; Skip the archiving step if the archive is up-to-date
         ;; or you don't want to update it:
         #:skip-archive? [skip-archive? #f]

         ;; Skip the building step if you know that everything is
         ;; built or you don't want to build:
         #:skip-build? [skip-build? #f]

         ;; Skip the doc-assembling step if you don't want docs:
         #:skip-docs? [skip-docs? #f]

         ;; Skip the summary step if you don't want the generated
         ;; web pages:
         #:skip-summary? [skip-summary? #f]
         ;; Omit specified packages from the summary:
         #:summary-omit-pkgs [summary-omit-pkgs null]

         ;; Timeout in seconds for any one package or step:
         #:timeout [timeout 600]

         ;; Building more than one package at a time case be faster,
         ;; but it risks success when a build should have failed due
         ;; to missing dependencies, and it risks corruption due to
         ;; especially broken or nefarious packages:
         #:max-build-together [max-build-together 1]         

         ;; Port to use on host machine for catalog server:
         #:server-port [server-port 18333])

  (current-timeout timeout)
  (current-tunnel-port server-port)

  (unless (and (list? vms)
               ((length vms) . >= . 1)
               (andmap vm? vms))
    (error 'build-pkgs "expected a non-empty list of `vm`s"))
  
  (define work-dir (path->complete-path given-work-dir))
  (define installer-dir (build-path work-dir "installer"))
  (define server-dir (build-path work-dir "server"))
  (define archive-dir (build-path server-dir "archive"))
  (define state-file (build-path work-dir "state.sqlite"))

  (define built-dir (build-path server-dir "built"))
  (define built-pkgs-dir (build-path built-dir "pkgs/"))
  (define built-catalog-dir (build-path built-dir "catalog"))
  (define fail-dir (build-path built-dir "fail"))
  (define success-dir (build-path built-dir "success"))
  (define install-success-dir (build-path built-dir "install"))
  (define deps-fail-dir (build-path built-dir "deps"))

  (define dumpster-dir (build-path work-dir "dumpster"))
  (define dumpster-pkgs-dir (build-path dumpster-dir "pkgs/"))
  (define dumpster-adds-dir (build-path dumpster-dir "adds"))

  (define snapshot-catalog
    (url->string
     (combine-url/relative (string->url snapshot-url)
                           "catalog")))

  (make-directory* work-dir)

  ;; ----------------------------------------

  (define (q s)
    (~a "\"" s "\""))

  (define (at-vm vm dest)
    (~a (remote-user+host vm) ":" dest))

  (define (cd-racket vm) (~a "cd " (q (remote-dir vm)) "/racket"))

  ;; ----------------------------------------
  (status "Getting installer table\n")
  (define table (call/input-url
                 (combine-url/relative (string->url snapshot-url)
                                       "installers/table.rktd")
                 get-pure-port
                 (lambda (i) (read i))))

  (define installer-name (hash-ref table installer-platform-name))

  ;; ----------------------------------------
  (status "Getting installer ~a\n" installer-name)
  (delete-directory/files installer-dir #:must-exist? #f)
  (make-directory* installer-dir)
  (call/input-url
   (combine-url/relative (string->url snapshot-url)
                         (~a "installers/" installer-name))
   get-pure-port
   (lambda (i)
     (call-with-output-file*
      (build-path installer-dir installer-name)
      #:exists 'replace
      (lambda (o)
        (copy-port i o)))))

  ;; ----------------------------------------
  (unless skip-archive?
    (status "Archiving packages from\n")
    (show-list (cons snapshot-catalog pkg-catalogs))
    (make-directory* archive-dir)
    (pkg-catalog-archive archive-dir
                         (cons snapshot-catalog pkg-catalogs)
                         #:state-catalog state-file
                         #:relative-sources? #t
                         #:package-exn-handler (lambda (name exn)
                                                 (log-error "~a\nSKIPPING ~a"
                                                            (exn-message exn)
                                                            name))))

  (define snapshot-pkg-names
    (parameterize ([current-pkg-catalogs (list (string->url snapshot-catalog))])
      (get-all-pkg-names-from-catalogs)))

  (define all-pkg-names
    (parameterize ([current-pkg-catalogs (list (path->url (build-path archive-dir "catalog")))])
      (get-all-pkg-names-from-catalogs)))

  (define pkg-details
    (parameterize ([current-pkg-catalogs (list (path->url (build-path archive-dir "catalog")))])
      (get-all-pkg-details-from-catalogs)))

  (define (install vm #:one-time? [one-time? #f])
    ;; ----------------------------------------
    (status "Starting VM ~a\n" (vm-name vm))
    (stop-vbox-vm (vm-name vm))
    (restore-vbox-snapshot (vm-name vm) (vm-init-snapshot vm))
    (start-vbox-vm (vm-name vm))

    (dynamic-wind
     void
     (lambda ()
       ;; ----------------------------------------
       (status "Fixing time at ~a\n" (vm-name vm))
       (ssh vm "sudo date --set=" (q (parameterize ([date-display-format 'rfc2822])
                                       (date->string (seconds->date (current-seconds)) #t))))

       ;; ----------------------------------------
       (define there-dir (remote-dir vm))
       (status "Preparing directory ~a\n" there-dir)
       (ssh vm "rm -rf " (~a (q there-dir) "/*"))
       (ssh vm "mkdir -p " (q there-dir))
       (ssh vm "mkdir -p " (q (~a there-dir "/user")))
       (ssh vm "mkdir -p " (q (~a there-dir "/built")))
       
       (scp vm (build-path installer-dir installer-name) (at-vm vm there-dir))
       
       (ssh vm "cd " (q there-dir) " && " " sh " (q installer-name) " --in-place --dest ./racket")
       
       ;; VM-side helper modules:
       (scp vm pkg-adds-rkt (at-vm vm (~a there-dir "/pkg-adds.rkt")))
       (scp vm pkg-list-rkt (at-vm vm (~a there-dir "/pkg-list.rkt")))

       (when one-time?
         ;; ----------------------------------------
         (status "Getting installed packages\n")
         (ssh vm (cd-racket vm)
              " && bin/racket ../pkg-list.rkt > ../pkg-list.rktd")
         (scp vm (at-vm vm (~a there-dir "/pkg-list.rktd"))
              (build-path work-dir "install-list.rktd")))

       ;; ----------------------------------------
       (status "Setting catalogs at ~a\n" (vm-name vm))
       (ssh vm (cd-racket vm)
            " && bin/raco pkg config -i --set catalogs "
            " http://localhost:" server-port "/built/catalog/"
            " http://localhost:" server-port "/archive/catalog/")

       (when one-time?
         ;; ----------------------------------------
         (status "Stashing installation docs\n")
         (ssh vm (cd-racket vm)
              " && bin/racket ../pkg-adds.rkt --all > ../pkg-adds.rktd")
         (ssh vm (cd-racket vm)
              " && tar zcf ../install-doc.tgz doc")
         (scp vm (at-vm vm (~a there-dir "/pkg-adds.rktd"))
              (build-path work-dir "install-adds.rktd"))
         (scp vm (at-vm vm (~a there-dir "/install-doc.tgz"))
              (build-path work-dir "install-doc.tgz")))
       
       (void))
     (lambda ()
       (stop-vbox-vm (vm-name vm))))

    ;; ----------------------------------------
    (status "Taking installation snapshopt\n")
    (when (exists-vbox-snapshot? (vm-name vm) (vm-installed-snapshot vm))
      (delete-vbox-snapshot (vm-name vm) (vm-installed-snapshot vm)))
    (take-vbox-snapshot (vm-name vm) (vm-installed-snapshot vm)))

  (unless skip-install?
    (install (car vms) #:one-time? #t)
    (map install (cdr vms)))
  
  ;; ----------------------------------------
  (status "Resetting ready content of ~a\n" built-pkgs-dir)

  (make-directory* built-pkgs-dir)

  (define installed-pkg-names
    (call-with-input-file* (build-path work-dir "install-list.rktd") read))

  (substatus "Total number of packages: ~a\n" (length all-pkg-names))
  (substatus "Packages installed already: ~a\n" (length installed-pkg-names))

  (define snapshot-pkgs (list->set snapshot-pkg-names))
  (define installed-pkgs (list->set installed-pkg-names))

  (define try-pkgs (set-subtract (list->set all-pkg-names)
                                 installed-pkgs))

  (define (pkg-checksum pkg) (hash-ref (hash-ref pkg-details pkg) 'checksum ""))
  (define (pkg-checksum-file pkg) (build-path built-pkgs-dir (~a pkg ".orig-CHECKSUM")))
  (define (pkg-zip-file pkg) (build-path built-pkgs-dir (~a pkg ".zip")))
  (define (pkg-zip-checksum-file pkg) (build-path built-pkgs-dir (~a pkg ".zip.CHECKSUM")))
  (define (pkg-failure-dest pkg) (build-path fail-dir pkg))

  (define failed-pkgs
    (for/set ([pkg (in-list all-pkg-names)]
              #:when
              (let ()
                (define checksum (pkg-checksum pkg))
                (define checksum-file (pkg-checksum-file pkg))
                (and (file-exists? checksum-file)
                     (equal? checksum (file->string checksum-file))
                     (not (set-member? installed-pkgs pkg))
                     (file-exists? (pkg-failure-dest pkg)))))
      pkg))

  (define changed-pkgs
    (for/set ([pkg (in-list all-pkg-names)]
              #:unless
              (let ()
                (define checksum (pkg-checksum pkg))
                (define checksum-file (pkg-checksum-file pkg))
                (and (file-exists? checksum-file)
                     (equal? checksum (file->string checksum-file))
                     (or (set-member? installed-pkgs pkg)
                         (file-exists? (pkg-failure-dest pkg))
                         (and
                          (file-exists? (pkg-zip-file pkg))
                          (file-exists? (pkg-zip-checksum-file pkg)))))))
      pkg))

  (define (pkg-deps pkg)
    (map (lambda (dep) 
           (define d (if (string? dep) dep (car dep)))
           (if (equal? d "racket") "base" d))
         (hash-ref (hash-ref pkg-details pkg) 'dependencies null)))

  (define update-pkgs
    (let loop ([update-pkgs changed-pkgs])
       (define more-pkgs
         (for/set ([pkg (in-set try-pkgs)]
                   #:when (and (not (set-member? update-pkgs pkg))
                               (for/or ([dep (in-list (pkg-deps pkg))])
                                 (set-member? update-pkgs dep))))
           pkg))
       (if (set-empty? more-pkgs)
           update-pkgs
           (loop (set-union more-pkgs update-pkgs)))))

  ;; Remove any ".zip[.CHECKSUM]" for packages that need to be built
  (for ([pkg (in-set update-pkgs)])
    (define checksum-file (pkg-checksum-file pkg))
    (when (file-exists? checksum-file) (delete-file checksum-file))
    (define zip-file (pkg-zip-file pkg))
    (when (file-exists? zip-file) (delete-file zip-file))
    (define zip-checksum-file (pkg-zip-checksum-file pkg))
    (when (file-exists? zip-checksum-file) (delete-file zip-checksum-file)))

  ;; For packages in the installation, remove any ".zip[.CHECKSUM]" and set ".orig-CHECKSUM"
  (for ([pkg (in-set installed-pkgs)])
    (define checksum-file (pkg-checksum-file pkg))
    (define zip-file (pkg-zip-file pkg))
    (define zip-checksum-file (pkg-zip-checksum-file pkg))
    (define failure-dest (pkg-failure-dest pkg))
    (when (file-exists? zip-file) (delete-file zip-file))
    (when (file-exists? zip-checksum-file) (delete-file zip-checksum-file))
    (when (file-exists? failure-dest) (delete-file failure-dest))
    (call-with-output-file*
     checksum-file
     #:exists 'truncate/replace
     (lambda (o)
       (write-string (pkg-checksum pkg) o))))

  (define need-pkgs (set-subtract (set-subtract update-pkgs installed-pkgs)
                                  failed-pkgs))

  (define cycles (make-hash)) ; for union-find

  ;; Sort needed packages based on dependencies, and accumulate cycles:
  (define need-rep-pkgs-list
    (let loop ([l (sort (set->list need-pkgs) string<?)] [seen (set)] [cycle-stack null])
      (if (null? l)
          null
          (let ([pkg (car l)])
            (cond
             [(member pkg cycle-stack)
              ;; Hit a package while processing its dependencies;
              ;; everything up to that package on the stack is
              ;; mutually dependent:
              (for ([s (in-list (member pkg (reverse cycle-stack)))])
                (union! cycles pkg s))
              (loop (cdr l) seen cycle-stack)]
             [(set-member? seen pkg)
              (loop (cdr l) seen cycle-stack)]
             [else
              (define pkg (car l))
              (define new-seen (set-add seen pkg))
              (define deps
                (for/list ([dep (in-list (pkg-deps pkg))]
                           #:when (set-member? need-pkgs dep))
                  dep))
              (define pre (loop deps new-seen (cons pkg cycle-stack)))
              (define pre-seen (set-union new-seen (list->set pre)))
              (define remainder (loop (cdr l) pre-seen cycle-stack))
              (elect! cycles pkg) ; in case of mutual dependency, follow all pre-reqs
              (append pre (cons pkg remainder))])))))

  ;; A list that contains strings and lists of strings, where a list
  ;; of strings represents mutually dependent packages:
  (define need-pkgs-list
    (let ([reps (make-hash)])
      (for ([pkg (in-set need-pkgs)])
        (hash-update! reps (find! cycles pkg) (lambda (l) (cons pkg l)) null))
      (for/list ([pkg (in-list need-rep-pkgs-list)]
                 #:when (equal? pkg (find! cycles pkg)))
        (define pkgs (hash-ref reps pkg))
        (if (= 1 (length pkgs))
            pkg
            pkgs))))

  (substatus "Packages that we need:\n")
  (show-list need-pkgs-list)

  ;; ----------------------------------------
  (status "Preparing built catalog at ~a\n" built-catalog-dir)

  (define (update-built-catalog given-pkgs)
    ;; Don't shadow anything from the catalog, even if we "built" it to
    ;; get documentation:
    (define pkgs (filter (lambda (pkg) (not (set-member? snapshot-pkgs pkg)))
                         given-pkgs))
    ;; Generate info for each now-built package:
    (define hts (for/list ([pkg (in-list pkgs)])
                  (let* ([ht (hash-ref pkg-details pkg)]
                         [ht (hash-set ht 'source (~a "../pkgs/" pkg ".zip"))]
                         [ht (hash-set ht 'checksum
                                       (file->string (build-path built-pkgs-dir
                                                                 (~a pkg ".zip.CHECKSUM"))))])
                    ht)))
    (for ([pkg (in-list pkgs)]
          [ht (in-list hts)])
      (call-with-output-file*
       (build-path built-catalog-dir "pkg" pkg)
       (lambda (o) (write ht o) (newline o))))
    (define old-all (call-with-input-file* (build-path built-catalog-dir "pkgs-all") read))
    (define all
      (for/fold ([all old-all]) ([pkg (in-list pkgs)]
                                 [ht (in-list hts)])
        (hash-set all pkg ht)))
    (call-with-output-file*
     (build-path built-catalog-dir "pkgs-all")
     #:exists 'truncate/replace
     (lambda (o)
       (write all o)
       (newline o)))
    (call-with-output-file*
     (build-path built-catalog-dir "pkgs")
     #:exists 'truncate/replace
     (lambda (o)
       (write (hash-keys all) o)
       (newline o))))

  (delete-directory/files built-catalog-dir #:must-exist? #f)
  (make-directory* built-catalog-dir)
  (make-directory* (build-path built-catalog-dir "pkg"))
  (call-with-output-file* 
   (build-path built-catalog-dir "pkgs-all")
   (lambda (o) (displayln "#hash()" o)))
  (call-with-output-file* 
   (build-path built-catalog-dir "pkgs")
   (lambda (o) (displayln "()" o)))
  (update-built-catalog (set->list (set-subtract
                                    (set-subtract try-pkgs need-pkgs)
                                    failed-pkgs)))

  ;; ----------------------------------------
  (status "Starting server at locahost:~a for ~a\n" server-port archive-dir)
  
  (define server
    (thread
     (lambda ()
       (serve/servlet
        (lambda args #f)
        #:command-line? #t
        #:listen-ip "localhost"
        #:extra-files-paths (list server-dir)
        #:servlet-regexp #rx"$." ; never match
        #:port server-port))))
  (sync (system-idle-evt))

  ;; ----------------------------------------
  (make-directory* (build-path built-dir "adds"))
  (make-directory* fail-dir)
  (make-directory* success-dir)
  (make-directory* install-success-dir)
  (make-directory* deps-fail-dir)

  (make-directory* dumpster-pkgs-dir)
  (make-directory* dumpster-adds-dir)

  (define (pkg-adds-file pkg)
    (build-path built-dir "adds" (format "~a-adds.rktd" pkg)))

  (define (complain failure-dest fmt . args)
    (when failure-dest
      (call-with-output-file*
       failure-dest
       #:exists 'truncate/replace
       (lambda (o) (apply fprintf o fmt args))))
    (apply eprintf fmt args)
    #f)

  ;; Build one package or a group of packages:
  (define (build-pkgs vm pkgs)
    (define flat-pkgs (flatten pkgs))
    ;; one-pkg can be a list in the case of mutual dependencies:
    (define one-pkg (and (= 1 (length pkgs)) (car pkgs)))
    (define pkgs-str (apply ~a #:separator " " flat-pkgs))

    (status (~a (make-string 40 #\=) "\n"))
    (if one-pkg
        (if (pair? one-pkg)
            (begin
              (status "Building mutually dependent packages:\n")
              (show-list one-pkg))
            (status "Building ~a\n" one-pkg))
        (begin
          (status "Building packages together:\n")
          (show-list pkgs)))

    (define failure-dest (and one-pkg
                              (pkg-failure-dest (car flat-pkgs))))
    (define install-success-dest (build-path install-success-dir
                                             (car flat-pkgs)))

    (define (pkg-deps-failure-dest pkg)
      (build-path deps-fail-dir pkg))
    (define deps-failure-dest (and one-pkg
                                   (pkg-deps-failure-dest (car flat-pkgs))))

    (define (save-checksum pkg)
      (call-with-output-file*
       (build-path built-pkgs-dir (~a pkg ".orig-CHECKSUM"))
       #:exists 'truncate/replace
       (lambda (o) (write-string (pkg-checksum pkg) o))))

    (define there-dir (remote-dir vm))

    (for ([pkg (in-list flat-pkgs)])
      (define f (build-path install-success-dir pkg))
      (when (file-exists? f) (delete-file f)))

    (restore-vbox-snapshot (vm-name vm) (vm-installed-snapshot vm))
    (start-vbox-vm (vm-name vm) #:max-vms (length vms))
    (dynamic-wind
     void
     (lambda ()
       (define ok?
         (and
          ;; Try to install:
          (ssh #:show-time? #t
               vm (cd-racket vm)
               " && bin/raco pkg install -u --auto"
               (if one-pkg "" " --fail-fast")
               " " pkgs-str
               #:mode 'result
               #:failure-dest failure-dest
               #:success-dest install-success-dest)
          ;; Copy success log for other packages in the group:
          (for ([pkg (in-list (cdr flat-pkgs))])
            (copy-file install-success-dest
                       (build-path install-success-dir pkg)
                       #t))
          (let ()
            ;; Make sure that any extra installed packages used were previously
            ;; built, since we want built packages to be consistent with a binary
            ;; installation.
            (ssh #:show-time? #t
                 vm (cd-racket vm)
                 " && bin/racket ../pkg-list.rkt --user > ../user-list.rktd")
            (scp vm (at-vm vm (~a there-dir "/user-list.rktd"))
                 (build-path work-dir "user-list.rktd"))
            (define new-pkgs (call-with-input-file*
                              (build-path work-dir "user-list.rktd")
                              read))
            (for/and ([pkg (in-list new-pkgs)])
              (or (member pkg flat-pkgs)
                  (set-member? installed-pkgs pkg)
                  (file-exists? (build-path built-catalog-dir "pkg" pkg))
                  (complain failure-dest
                            (~a "use of package not previously built: ~s;\n"
                                " maybe a dependency is missing, or maybe the package\n"
                                " failed to build on its own\n")
                            pkg))))))
       (define deps-ok?
         (and ok?
              (ssh #:show-time? #t
                   vm (cd-racket vm)
                   " && bin/raco setup -nxiID --check-pkg-deps --pkgs "
                   " " pkgs-str
                   #:mode 'result
                   #:failure-dest deps-failure-dest)))
       (when (and ok? one-pkg (not deps-ok?))
         ;; Copy dependency-failure log for other packages in the group:
         (for ([pkg (in-list (cdr flat-pkgs))])
           (copy-file install-success-dest
                      (pkg-deps-failure-dest pkg)
                      #t)))
       (define doc-ok?
         (and
          ;; If we're building a single package (or set of mutually
          ;; dependent packages), then try to save generated documentation
          ;; even on failure. We'll put it in the "dumpster".
          (or ok? one-pkg)
          (ssh vm (cd-racket vm)
               " && bin/racket ../pkg-adds.rkt " pkgs-str
               " > ../pkg-adds.rktd"
               #:mode 'result
               #:failure-dest (and ok? failure-dest))
          (for/and ([pkg (in-list flat-pkgs)])
            (ssh vm (cd-racket vm)
                 " && bin/raco pkg create --from-install --built"
                 " --dest " there-dir "/built"
                 " " pkg
                 #:mode 'result
                 #:failure-dest (and ok? failure-dest)))))
       (cond
        [(and ok? doc-ok? (or deps-ok? one-pkg))
         (for ([pkg (in-list flat-pkgs)])
           (when (file-exists? (pkg-failure-dest pkg))
             (delete-file (pkg-failure-dest pkg)))
           (when (and deps-ok? (file-exists? (pkg-deps-failure-dest pkg)))
             (delete-file (pkg-deps-failure-dest pkg)))
           (scp vm (at-vm vm (~a there-dir "/built/" pkg ".zip"))
                built-pkgs-dir)
           (scp vm (at-vm vm (~a there-dir "/built/" pkg ".zip.CHECKSUM"))
                built-pkgs-dir)
           (scp vm (at-vm vm (~a there-dir "/pkg-adds.rktd"))
                (build-path built-dir "adds" (format "~a-adds.rktd" pkg)))
           (define deps-msg (if deps-ok? "" ", but problems with dependency declarations"))
           (call-with-output-file*
            (build-path success-dir pkg)
            #:exists 'truncate/replace
            (lambda (o)
              (if one-pkg
                  (fprintf o "success~a\n" deps-msg)
                  (fprintf o "success with ~s~a\n" pkgs deps-msg))))
           (save-checksum pkg))
         (update-built-catalog flat-pkgs)]
        [else
         (when one-pkg
           ;; Record failure (for all docs in a mutually dependent set):
           (for ([pkg (in-list flat-pkgs)])
             (when (list? one-pkg)
               (unless (equal? pkg (car one-pkg))
                 (copy-file failure-dest (pkg-failure-dest (car one-pkg)) #t)))
             (save-checksum pkg))
           ;; Keep any docs that might have been built:
           (for ([pkg (in-list flat-pkgs)])
             (scp vm (at-vm vm (~a there-dir "/built/" pkg ".zip"))
                  dumpster-pkgs-dir
                  #:mode 'ignore-failure)
             (scp vm (at-vm vm (~a there-dir "/built/" pkg ".zip.CHECKSUM"))
                  dumpster-pkgs-dir
                  #:mode 'ignore-failure)
             (scp vm (at-vm vm (~a there-dir "/pkg-adds.rktd"))
                  (build-path dumpster-adds-dir (format "~a-adds.rktd" pkg))
                  #:mode 'ignore-failure)))
         (substatus "*** failed ***\n")])
       ok?)
     (lambda ()
       (stop-vbox-vm (vm-name vm) #:save-state? #f))))

  ;; Build a group of packages, recurring on smaller groups
  ;; if the big group fails:
  (define (build-pkg-set vm pkgs)
    (define len (length pkgs))
    (define ok? (and (len . <= . max-build-together)
                     (build-pkgs vm pkgs)))
    (flush-chunk-output)
    (unless (or ok? (= 1 len))
      (define part (min (quotient len 2)
                        max-build-together))
      (build-pkg-set vm (take pkgs part))
      (build-pkg-set vm (drop pkgs part))))

  ;; Look for n packages whose dependencies are ready:
  (define (select-n n pkgs pending-pkgs)
    (cond
     [(zero? n) null]
     [(null? pkgs) null]
     [else
      (define pkg (car pkgs)) ; `pkg` can be a list of strings
      ;; Check for dependencies in `pending-pkgs`, but
      ;; we don't have to check dependencies transtively,
      ;; because the ordering of `pkgs` takes care of that.
      (cond
       [(ormap (lambda (dep) (set-member? pending-pkgs dep))
               (if (string? pkg)
                   (pkg-deps pkg)
                   (apply append (map pkg-deps pkg))))
        (select-n n (cdr pkgs) pending-pkgs)]
       [else
        (cons pkg
              (select-n (sub1 n) (cdr pkgs) pending-pkgs))])]))

  ;; try-pkgs has the same order as `pkgs`:
  (define (remove-ordered try-pkgs pkgs)
    (cond
     [(null? try-pkgs) pkgs]
     [(equal? (car try-pkgs) (car pkgs))
      (remove-ordered (cdr try-pkgs) (cdr pkgs))]
     [else
      (cons (car pkgs) (remove-ordered try-pkgs (cdr pkgs)))]))

  (struct running (vm pkgs th done?-box)
    #:property prop:evt (lambda (r)
                          (wrap-evt (running-th r)
                                    (lambda (v) r))))
  (define (start-running vm pkgs)
    (define done?-box (box #f))
    (define t (thread/chunk-output
               (lambda ()
                 (status "Sending to ~a:\n" (vm-name vm))
                 (show-list pkgs)
                 (flush-chunk-output)
                 (build-pkg-set vm pkgs)
                 (set-box! done?-box #t))))
    (running vm pkgs t done?-box))

  (define (break-running r)
    (break-thread (running-th r))
    (sync (running-th r)))

  ;; Build a group of packages, trying smaller
  ;; groups if the whole group fails or is too
  ;; big:
  (define (build-all-pkgs pkgs)
    ;; pkgs is a list of string and lists (for mutual dependency)
    (let loop ([pkgs pkgs]
               [pending-pkgs (list->set pkgs)]
               [vms vms]
               [runnings null]
               [error? #f])
      (define (wait)
        (define r
          (with-handlers ([exn:break? (lambda (exn)
                                        (log-error "breaking...")
                                        (for-each break-running runnings)
                                        (wait-chunk-output))])
            (parameterize-break
             #t
             (apply sync runnings))))
        (loop pkgs
              (set-subtract pending-pkgs (list->set (running-pkgs r)))
              (cons (running-vm r) vms)
              (remq r runnings)
              (or error? (not (unbox (running-done?-box r))))))
      (cond
       [error?
        (if (null? runnings)
            (error "a build task ended prematurely")
            (wait))]
       [(and (null? pkgs)
             (null? runnings))
        ;; Done
        (void)]
       [(null? vms)
        ;; All VMs busy; wait for one to finish
        (wait)]
       [else
        (define try-pkgs (select-n max-build-together pkgs pending-pkgs))
        (cond
         [(null? try-pkgs)
          ;; Nothing to do until a dependency finished; wait
          (wait)]
         [else
          (loop (remove-ordered try-pkgs pkgs)
                pending-pkgs
                (cdr vms)
                (cons (start-running (car vms) try-pkgs)
                      runnings)
                error?)])])))

  ;; Build all of the out-of-date packages:
  (unless skip-build?
    (if (= 1 (length vms))
        ;; Sequential builds:
        (build-pkg-set (car vms) need-pkgs-list)
        ;; Parallel builds:
        (parameterize-break
         #f
         (build-all-pkgs need-pkgs-list))))

  ;; ----------------------------------------
  (status "Assembling documentation\n")

  (define available-pkgs
    (for/set ([pkg (in-list all-pkg-names)]
              #:when
              (let ()
                (define checksum (pkg-checksum pkg))
                (define checksum-file (pkg-checksum-file pkg))
                (and (file-exists? checksum-file)
                     (file-exists? (pkg-zip-file pkg))
                     (file-exists? (pkg-zip-checksum-file pkg)))))
      pkg))

  (define adds-pkgs
    (for/hash ([pkg (in-set available-pkgs)])
      (define adds-file (pkg-adds-file pkg))
      (define ht (call-with-input-file* adds-file read))
      (values pkg (hash-ref ht pkg null))))
  
  (define doc-pkg-list
    (sort (for/list ([(k l) (in-hash adds-pkgs)]
                     #:when (for/or ([v (in-list l)])
                              (eq? (car v) 'doc)))
            k)
          string<?))

  (substatus "Packages with documentation:\n")
  (show-list doc-pkg-list)
  
  ;; `conflict-pkgs` have a direct conflict, while `no-conflict-pkgs`
  ;; have no direct conflict and no dependency with a conflict
  (define-values (conflict-pkgs no-conflict-pkgs)
    (let ()
      (define (add-providers ht pkgs)
        (for*/fold ([ht ht]) ([(k v) (in-hash pkgs)]
                              [(d) (in-list v)])
          (hash-update ht d (lambda (l) (set-add l k)) (set))))
      (define providers (add-providers (add-providers (hash) adds-pkgs)
                                       (call-with-input-file*
                                        (build-path work-dir "install-adds.rktd")
                                        read)))
      (define conflicts
        (for/list ([(k v) (in-hash providers)]
                   #:when ((set-count v) . > . 1))
          (cons k v)))
      (cond
       [(null? conflicts)
        available-pkgs]
       [else
        (define (show-conflicts)
          (substatus "Install conflicts:\n")
          (for ([v (in-list conflicts)])
            (substatus " ~a ~s:\n" (caar v) (cdar v))
            (show-list #:indent " " (sort (set->list (cdr  v)) string<?))))
        (show-conflicts)
        (with-output-to-file "conflicts"
          #:exists 'truncate/replace
          show-conflicts)
        (define conflicting-pkgs
          (for/fold ([s (set)]) ([v (in-list conflicts)])
            (set-union s (cdr v))))
        (define reverse-deps
          (for*/fold ([ht (hash)]) ([pkg (in-set available-pkgs)]
                                    [dep (in-list (pkg-deps pkg))])
            (hash-update ht dep (lambda (s) (set-add s pkg)) (set))))
        (define disallowed-pkgs
          (let loop ([pkgs conflicting-pkgs] [conflicting-pkgs conflicting-pkgs])
            (define new-pkgs (for*/set ([p (in-set conflicting-pkgs)]
                                        [rev-dep (in-set (hash-ref reverse-deps p (set)))]
                                        #:unless (set-member? pkgs rev-dep))
                               rev-dep))
            (if (set-empty? new-pkgs)
                pkgs
                (loop (set-union pkgs new-pkgs) new-pkgs))))
        (substatus "Packages disallowed due to conflicts:\n")
        (show-list (sort (set->list disallowed-pkgs) string<?))
        (values conflicting-pkgs
                (set-subtract available-pkgs disallowed-pkgs))])))

  (define no-conflict-doc-pkgs (set-intersect (list->set doc-pkg-list) no-conflict-pkgs))
  (define no-conflict-doc-pkg-list (sort (set->list no-conflict-doc-pkgs) string<?))

  (unless skip-docs?
    (define vm (car vms))
    (restore-vbox-snapshot (vm-name vm) (vm-installed-snapshot vm))
    (start-vbox-vm (vm-name vm))
    (dynamic-wind
     void
     (lambda ()
       (ssh #:show-time? #t
            vm (cd-racket vm)
            " && bin/raco pkg install -i --auto"
            " " (apply ~a #:separator " " no-conflict-doc-pkg-list))
       (ssh vm (cd-racket vm)
            " && tar zcf ../all-doc.tgz doc")
       (scp vm (at-vm vm (~a (remote-dir vm) "/all-doc.tgz"))
            (build-path work-dir "all-doc.tgz")))
     (lambda ()
       (stop-vbox-vm (vm-name vm) #:save-state? #f)))
    (untgz "all-doc.tgz"))
  
  ;; ----------------------------------------

  (unless skip-summary?
    (define (path->relative p)
      (define work (explode-path work-dir))
      (define dest (explode-path p))
      (unless (equal? work (take dest (length work)))
        (error "not relative"))
      (string-join (map path->string (drop dest (length work))) "/"))
    
    (define summary-ht
      (for/hash ([pkg (in-set (set-subtract try-pkgs
                                            (list->set summary-omit-pkgs)))])
        (define failed? (file-exists? (pkg-failure-dest pkg)))
        (define succeeded? (file-exists? (build-path install-success-dir pkg)))
        (define status
          (cond
           [(and failed? (not succeeded?)) 'failure]
           [(and succeeded? (not failed?)) 'success]
           [(and succeeded? failed?) 'confusion]
           [else 'unknown]))
        (define dep-status
          (if (eq? status 'success)
              (if (file-exists? (build-path deps-fail-dir pkg))
                  'failure
                  'success)
              'unknown))
        (define adds (let ([adds-file (if (eq? status 'success)
                                          (pkg-adds-file pkg)
                                          (build-path dumpster-adds-dir (format "~a-adds.rktd" pkg)))])
                       (if (file-exists? adds-file)
                           (hash-ref (call-with-input-file* adds-file read)
                                     pkg
                                     null)
                           null)))
        (define conflicts? (and (eq? status 'success)
                                (not (set-member? no-conflict-pkgs pkg))))
        (define docs (for/list ([add (in-list adds)]
                                #:when (eq? (car add) 'doc))
                       (cdr add)))
        (values
         pkg
         (hash 'success-log (and (or (eq? status 'success)
                                     (eq? status 'confusion))
                                 (path->relative (build-path install-success-dir pkg)))
               'failure-log (and (or (eq? status 'failure)
                                     (eq? status 'confusion))
                                 (path->relative (pkg-failure-dest pkg)))
               'dep-failure-log (and (eq? dep-status 'failure)
                                     (path->relative (build-path deps-fail-dir pkg)))
               'docs (for/list ([doc (in-list docs)])
                       (if (or (not (eq? status 'success))
                               conflicts?)
                           (doc/none doc)
                           (doc/main doc
                                     (~a "doc/" doc "/index.html"))))
               'conflicts-log (and conflicts?
                                   (if (set-member? conflict-pkgs pkg)
                                       "conflicts"
                                       (conflicts/indirect "conflicts")))))))

    (call-with-output-file*
     (build-path work-dir "summary.rktd")
     #:exists 'truncate/replace
     (lambda (o)
       (write summary-ht o)
       (newline o)))

    (summary-page summary-ht work-dir))

  ;; ----------------------------------------
  
  (void))
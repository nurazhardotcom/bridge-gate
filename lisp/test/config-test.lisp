;;;; config-test.lisp --- Configuration precedence and EDN file tests.

(defpackage #:bridge-gate/config-test
  (:use #:cl #:bridge-gate/test-support))

(in-package #:bridge-gate/config-test)

(defun temporary-edn-file (contents)
  (let ((path (merge-pathnames
               (format nil "bridge-gate-config-~a.edn" (random 1000000))
               (uiop:temporary-directory))))
    (with-open-file (stream path
                            :direction :output
                            :if-exists :supersede
                            :if-does-not-exist :create
                            :external-format :utf-8)
      (write-string contents stream))
    path))

(defmacro with-temporary-edn ((path contents) &body body)
  `(let ((,path (temporary-edn-file ,contents)))
     (unwind-protect (progn ,@body)
       (ignore-errors (delete-file ,path)))))

(deftest default-config
  (testing "load-config returns the documented defaults"
    (let ((config (bridge-gate.config:load-config)))
      (ok (eq :ccp (hget config :cyberark-mode)))
      (ok (eq :tenable-io (hget config :tenable-mode)))
      (ok (string= "default" (hget config :conjur-account)))
      (ok (= 10000 (hget config :poll-interval-ms)))
      (ok (= 60 (hget config :poll-max-attempts)))
      (ok (string= "policies/mas_trm.edn" (hget config :policy)))
      (ok (string= ".bridge/findings.json" (hget config :findings)))
      (ok (string= ".bridge/block.json" (hget config :report)))
      (ok (eq :false (hget config :mock))))))

(deftest file-config-overrides-defaults
  (testing "config.edn values override defaults"
    (with-temporary-edn (path "{:cyberark-mode :conjur
                               :conjur-account \"acme\"
                               :poll-max-attempts 5
                               :mock true}")
      (let ((config (bridge-gate.config:load-config (ht :config-file (namestring path)))))
        (ok (eq :conjur (hget config :cyberark-mode)))
        (ok (string= "acme" (hget config :conjur-account)))
        (ok (= 5 (hget config :poll-max-attempts)))
        (ok (eq t (hget config :mock)))))))

(deftest cli-overrides-file
  (testing "CLI flags override file values and nil flags are dropped"
    (with-temporary-edn (path "{:cyberark-mode :conjur :target \"from-file\"}")
      (let ((config (bridge-gate.config:load-config
                     (ht :config-file (namestring path)
                         :target "from-cli"
                         :policy nil))))
        (ok (string= "from-cli" (hget config :target)))
        (ok (string= "policies/mas_trm.edn" (hget config :policy)))
        (ok (eq :conjur (hget config :cyberark-mode)))))))

(deftest invalid-config-file-is-ignored
  (testing "a malformed config.edn falls back to defaults"
    (with-temporary-edn (path "{:unterminated")
      (let ((config (bridge-gate.config:load-config (ht :config-file (namestring path)))))
        (ok (eq :ccp (hget config :cyberark-mode)))))))

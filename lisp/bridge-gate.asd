;;;; lisp/bridge-gate.asd --- Enterprise compliance-as-code gate (SBCL port)

(asdf:defsystem "bridge-gate"
  :description "CyberArk credential fetch, Tenable scan normalization, and MAS TRM policy gate."
  :author "The Authors"
  :license "MIT"
  :version "0.2.1"
  :homepage "https://github.com/nurazhardotcom/bridge-gate"
  :depends-on ()
  :serial t
  :components ((:module "src"
                :components ((:file "package")
                             (:file "conditions")
                             (:file "util")
                             (:file "edn")
                             (:file "json")
                             (:file "http")
                             (:file "config")
                             (:file "policy")
                             (:file "cyberark")
                             (:file "tenable")
                             (:file "core"))))
  :in-order-to ((test-op (test-op "bridge-gate/tests"))))

(asdf:defsystem "bridge-gate/tests"
  :description "Self-contained test suite for bridge-gate (offline, mock-based)."
  :author "The Authors"
  :license "MIT"
  :version "0.2.1"
  :depends-on ("bridge-gate")
  :serial t
  :components ((:module "test"
                :components ((:file "support")
                             (:file "policy-test")
                             (:file "cyberark-test")
                             (:file "tenable-test")
                             (:file "config-test")
                             (:file "edn-test")
                             (:file "json-test"))))
  :perform (test-op (op component)
             (declare (ignore op component))
             (let ((failures (uiop:symbol-call
                              :bridge-gate/test-support :run-tests)))
               (unless (zerop failures)
                 (error "bridge-gate test suite failed (~a failure(s))" failures)))))

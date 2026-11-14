;;;; package.lisp --- Package definitions for bridge-gate.

(defpackage #:bridge-gate.conditions
  (:use #:cl)
  (:export #:app-error
           #:app-error-message
           #:app-error-detail
           #:app-error*))

(defpackage #:bridge-gate.util
  (:use #:cl)
  (:export #:whitespace-char-p
           #:trim
           #:blankp
           #:to-string
           #:keyword-name
           #:string-join
           #:starts-with-p
           #:ends-with-p
           #:replace-all
           #:strip-trailing-slash
           #:strip-leading-slashes
           #:truthy
           #:boolean-value
           #:make-map
           #:map-get
           #:map-has-p
           #:map-set
           #:copy-map
           #:map-keys
           #:map-values
           #:map-remove
           #:merge-maps
           #:alist->map
           #:pr-str
           #:coerce-severity
           #:severity-rank
           #:severity-key-p))

(defpackage #:bridge-gate.edn
  (:use #:cl)
  (:export #:edn-error
           #:edn-error-message
           #:read-edn
           #:read-edn-file))

(defpackage #:bridge-gate.json
  (:use #:cl)
  (:export #:json-error
           #:json-error-message
           #:parse
           #:parse-file
           #:stringify
           #:write-pretty
           #:write-compact))

(defpackage #:bridge-gate.http
  (:use #:cl)
  (:export #:default-client))

(defpackage #:bridge-gate.config
  (:use #:cl)
  (:export #:defaults
           #:env-config
           #:file-config
           #:load-config))

(defpackage #:bridge-gate.policy
  (:use #:cl)
  (:export #:severity-rank
           #:severity-of
           #:load-policy
           #:evaluate
           #:build-block-payload))

(defpackage #:bridge-gate.cyberark
  (:use #:cl)
  (:export #:mock-credential
           #:default-client
           #:fetch-credential))

(defpackage #:bridge-gate.tenable
  (:use #:cl)
  (:export #:coerce-severity
           #:default-client
           #:mock-scan
           #:run-scan))

(defpackage #:bridge-gate.core
  (:use #:cl)
  (:export #:main
           #:entry
           #:usage
           #:parse-cli))

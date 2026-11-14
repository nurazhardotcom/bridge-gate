;;;; json-test.lisp --- JSON parsing and deterministic emission tests.

(defpackage #:bridge-gate/json-test
  (:use #:cl #:bridge-gate/test-support))

(in-package #:bridge-gate/json-test)

(deftest parses-objects-and-arrays
  (testing "objects become hash tables, arrays become vectors"
    (let* ((value (bridge-gate.json:parse
                   "{\"a\":1,\"b\":[1,2],\"c\":{\"d\":true}}"))
           (nested (hget value "c")))
      (ok (= 1 (hget value "a")))
      (ok (vectorp (hget value "b")))
      (ok (= 2 (length (hget value "b"))))
      (ok (hash-table-p nested))
      (ok (eq t (hget nested "d"))))))

(deftest parses-false-and-null
  (testing "false arrives as :FALSE and null as NIL"
    (let ((value (bridge-gate.json:parse
                  "{\"no\":false,\"none\":null,\"yes\":true}")))
      (ok (eq :false (hget value "no")))
      (ok (null (hget value "none")))
      (ok (eq t (hget value "yes"))))))

(deftest keywordize-keys
  (testing "keywordize turns object keys into keywords recursively"
    (let* ((value (bridge-gate.json:parse
                   "{\"plugin-id\":10001,\"nested\":{\"host\":\"h\"}}"
                   :keywordize t))
           (nested (hget value :nested)))
      (ok (= 10001 (hget value :plugin-id)))
      (ok (string= "h" (hget nested :host))))))

(deftest emits-explicit-booleans
  (testing "T -> true, :FALSE -> false, NIL -> null"
    (let ((text (bridge-gate.json:stringify
                 (ht :yes t :no :false :none nil))))
      (ok (search "\"yes\":true" text))
      (ok (search "\"no\":false" text))
      (ok (search "\"none\":null" text)))))

(deftest emits-empty-array
  (testing "an empty vector is [] and never null"
    (ok (string= "[]" (bridge-gate.json:stringify (vector))))
    (ok (string= "{\"items\":[]}"
                 (bridge-gate.json:stringify (ht :items (vector)))))))

(deftest emits-kebab-keys-and-keyword-values
  (testing "keyword keys become kebab-case strings, keyword values lowercase strings"
    (ok (string= "{\"max-highs\":\"critical\"}"
                 (bridge-gate.json:stringify
                  (ht :max-highs :critical))))))

(deftest emits-sorted-keys
  (testing "object keys are emitted in sorted order for determinism"
    (ok (string= "{\"a\":1,\"b\":2,\"c\":3}"
                 (bridge-gate.json:stringify
                  (ht :c 3 :a 1 :b 2))))))

(deftest pretty-round-trip
  (testing "pretty output parses back to the same values"
    (let* ((original (ht :target "10.0.0.1"
                         :findings (vector (ht :plugin-id "10180"
                                                :severity :info)
                                           (ht :plugin-id "10001"
                                                :severity :critical))))
           (text (bridge-gate.json:stringify original :pretty t))
           (reparsed (bridge-gate.json:parse text)))
      (ok (search (string #\Newline) text))
      (ok (string= "10.0.0.1" (hget reparsed "target")))
      (ok (= 2 (length (hget reparsed "findings"))))
      (ok (string= "10001"
                   (hget (aref (hget reparsed "findings") 1) "plugin-id"))))))

(deftest escapes-strings
  (testing "quotes, backslashes, and control characters are escaped"
    (let ((text (bridge-gate.json:stringify
                 (ht :s (format nil "a\"b\\c~%d")))))
      (ok (search "\\\"b" text))
      (ok (search "\\\\c" text))
      (ok (search "\\n" text)))))

(deftest parses-file
  (testing "parse-file reads JSON from disk"
    (let ((path (merge-pathnames
                 (format nil "bridge-gate-json-~a.json" (random 1000000))
                 (uiop:temporary-directory))))
      (unwind-protect
           (progn
             (with-open-file (stream path
                                     :direction :output
                                     :if-exists :supersede
                                     :if-does-not-exist :create)
               (write-string "{\"findings\":[]}" stream))
             (let ((value (bridge-gate.json:parse-file path)))
               (ok (vectorp (hget value "findings")))
               (ok (zerop (length (hget value "findings"))))))
        (ignore-errors (delete-file path))))))

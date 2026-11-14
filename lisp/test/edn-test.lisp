;;;; edn-test.lisp --- EDN reader coverage.

(defpackage #:bridge-gate/edn-test
  (:use #:cl #:bridge-gate/test-support))

(in-package #:bridge-gate/edn-test)

(deftest reads-scalars
  (testing "keywords, strings, numbers, booleans, and nil"
    (ok (eq :conjur (bridge-gate.edn:read-edn ":conjur")))
    (ok (string= "hello" (bridge-gate.edn:read-edn "\"hello\"")))
    (ok (= 42 (bridge-gate.edn:read-edn "42")))
    (ok (= -7 (bridge-gate.edn:read-edn "-7")))
    (ok (eq t (bridge-gate.edn:read-edn "true")))
    (ok (eq :false (bridge-gate.edn:read-edn "false")))
    (ok (null (bridge-gate.edn:read-edn "nil")))))

(deftest reads-collections
  (testing "vectors, lists, maps, and sets"
    (ok (equalp (vector 1 2 3) (bridge-gate.edn:read-edn "[1 2 3]")))
    (ok (equal '(1 2 3) (bridge-gate.edn:read-edn "(1 2 3)")))
    (let ((map (bridge-gate.edn:read-edn "{:a 1, :b [2 3]}")))
      (ok (= 1 (hget map :a)))
      (ok (equalp (vector 2 3) (hget map :b))))
    (let ((set-value (bridge-gate.edn:read-edn "#{10001 20002}")))
      (ok (member 10001 set-value))
      (ok (member 20002 set-value)))))

(deftest handles-comments-and-discards
  (testing "; comments, #_ discards, and comma whitespace"
    (let ((map (bridge-gate.edn:read-edn
                "{;; leading comment
                  :a 1 #_ :ignored
                  :b 2}")))
      (ok (= 1 (hget map :a)))
      (ok (= 2 (hget map :b)))
      (ok (not (hhas map :ignored))))))

(deftest reads-string-escapes
  (testing "escaped quotes, newlines, tabs, and unicode"
    (let ((value (bridge-gate.edn:read-edn "\"a\\\"b\\nc\\td\\u00e9\"")))
      (ok (string= (concatenate 'string "a\"b" (string #\Newline)
                                "c" (string #\Tab) "d" (string (code-char #xe9)))
                   value)))))

(deftest empty-input-is-nil
  (testing "an empty document reads as nil"
    (ok (null (bridge-gate.edn:read-edn "")))
    (ok (null (bridge-gate.edn:read-edn "   ;; only a comment")))))

(deftest malformed-input-signals
  (testing "unterminated strings and maps signal an EDN error"
    (ok (signals-p (lambda () (bridge-gate.edn:read-edn "\"unterminated"))))
    (ok (signals-p (lambda () (bridge-gate.edn:read-edn "{:a 1"))))))

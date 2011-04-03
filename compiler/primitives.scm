;; -*- mode: scheme; coding: utf-8 -*-
;; Copyright (C) 2011 Göran Weinholt <goran@weinholt.se>

;; Permission is hereby granted, free of charge, to any person obtaining a copy
;; of this software and associated documentation files (the "Software"), to deal
;; in the Software without restriction, including without limitation the rights
;; to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
;; copies of the Software, and to permit persons to whom the Software is
;; furnished to do so, subject to the following conditions:

;; The above copyright notice and this permission notice shall be included in
;; all copies or substantial portions of the Software.

;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
;; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
;; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
;; THE SOFTWARE.

;; Definitions for primitive operations

(define *primitives* '())
(define *operations* '())

;; Primitives check the argument list of the primitive and then return
;; a operation name.
(define (add-primitive! name proc)
  (set! *primitives* (cons (cons name proc)
                           *primitives*)))

(define-macro (define-primitive name/args . body)
  (list 'add-primitive! (list 'quote (car name/args))
        (append (list 'lambda (cdr name/args))
                body)))

;; Operations are written in Go and are used to implement the primitives.
(define (add-operation! name proc)
  (set! *operations* (cons (cons name proc)
                           *operations*)))

(define-macro (define-operation name . body)
  (list 'add-operation! (list 'quote name)
        (append (list 'lambda '())
                body)))

(define (shift-args) "code = cdr(code)")
(define (argn n)
  (case n
    ((0) "ev(car(code), false, lexenv)")
    ((1) "ev(car(cdr(code)), false, lexenv)")
    (else
     (error 'argn "TODO: generalize to n" n))))

(define (normal-call funcname args)
  (let lp ((i 0) (ret '()) (formals ""))
    (if (= i args)
        (reverse (cons (string-append "return " funcname "(" formals ")") ret))
        (lp (+ i 1)
            (cons (string-append
                   "arg" (number->string i)
                   " := " (argn 0)
                   (if (< i (- args 1))
                       (string-append ";" (shift-args))
                       ""))
                  ret)
            (string-append formals (if (positive? i) ", arg" "arg")
                           (number->string i))))))

(define (print-operations p)
  (display "// This file is part of conscheme\n" p)
  (display "// Automatically generated by compiler/primitives.scm\n" p)
  (display "package conscheme\n" p)
  (display "import \"fmt\"\n" p)
  (display "import \"os\"\n" p)
  (display "func evprim(primop string, code Obj, lexenv map[string]Obj) Obj {\n" p)
  (display "\tswitch primop {\n" p)
  (for-each (lambda (op)
              (display (string-append "\tcase \"" (symbol->string (car op)) "\":\n") p)
              (for-each (lambda (line)
                          (display (string-append "\t\t" line "\n") p))
                        ((cdr op))))
            *operations*)
  (display "\tdefault:\n" p)
  (display "\t\tfmt.Fprintf(os.Stderr, \"Please regenerate primitives.go\\n\")\n" p)
  (display "\t\tpanic(fmt.Sprintf(\"Unimplemented primitive: %s\",primop))\n" p)
  (display "\t}\n" p)
  (display "\tpanic(fmt.Sprintf(\"Fell off the edge in evprim(): %s\",primop))\n" p)
  (display "}\n" p))

;; Pairs

(define-operation cons/2 (normal-call "Cons" 2))
(define-primitive (cons args)
  (if (= (length args) 2)
      'cons/2
      'ERROR))

;; Symbols

(define-operation symbol?/1 (normal-call "symbol_p" 1))
(define-primitive (symbol? args)
  (if (= (length args) 1)
      'symbol?/1
      'ERROR))

;; Misc

(define-operation unspecified/0 (list "return Void"))
(define-primitive (unspecified args)
  (if (= (length args) 0)
      'unspecified/0
      'ERROR))

(define-operation eq?/2
   (list (string-append "if " (argn 0) " == " (argn 1) " {")
         "\treturn True"
         "} else {"
         "\treturn False"
         "}"))
(define-primitive (eq? args)
  (if (= (length args) 2)
      'eq?/2
      'ERROR))

(define-operation exit/1
  (list (string-append "os.Exit(number_to_int(" (argn 0) "))")))
(define-primitive (exit args)
  (case (length args)
    ((1) 'exit/1)
    (else 'ERROR)))

;; I/O

(define-operation display/1 (normal-call "Display" 1))
(define-primitive (display args)
  ;; TODO: display with the port argument
  (if (= (length args) 1)
      'display/1
      'ERROR))

;;; A compiler pass

(define (lookup-primop x)
  (let ((x (assq x *primitives*)))
    (if x (cdr x) #f)))

(define (primcall primop name args)
  (let ((call (primop args)))
    (cond ((eq? call 'ERROR)
           (display "Warning: wrong number of arguments to built-in procedure:\n"
                    (current-error-port))
           (pretty-print (cons name args) (current-error-port))
           (newline (current-error-port))
           (primops (list 'begin (cons 'begin args)
                          (list 'error (list 'quote "Wrong number of arguments")
                                (list 'quote name)))))
          (else
           (cons '$primcall (cons call args))))))

;; The input is from aconv. The output language differentiates between
;; calls to known primitives and calls to closures.
(define (primops x)
  (if (symbol? x)
      (if (lookup-primop x)
          ;; TODO: generate lambda expressions for primitives
          (list '$primitive x)
          x)
      (case (car x)
        ((lambda)
         (list 'lambda (lambda-formals x) (primops (lambda-body x))))
        ((if)
         (cons 'if (map (lambda (x) (primops x)) (cdr x))))
        ((quote) x)
        ((define)
         (list 'define (cadr x) (primops (caddr x))))
        ((begin)
         (cons 'begin (map (lambda (x) (primops x)) (cdr x))))
        ((set!)
         (list 'set! (set!-name x) (primops (set!-expression x))))
        (else
         (let ((primop (and (pair? x) (lookup-primop (car x)))))
           (if primop
               (primcall primop (car x) (map (lambda (x) (primops x)) (cdr x)))
               (cons '$funcall (map (lambda (x) (primops x)) x))))))))
#lang racket

;; Example from the Erlang Programming Examples section of the Erlang User's Guide:
;;
;; -define(IP_VERSION, 4).
;; -define(IP_MIN_HDR_LEN, 5).
;; DgramSize = byte_size(Dgram),
;; case Dgram of
;;     <<?IP_VERSION:4, HLen:4, SrvcType:8, TotLen:16,
;;       ID:16, Flgs:3, FragOff:13,
;;       TTL:8, Proto:8, HdrChkSum:16,
;;       SrcIP:32,
;;       DestIP:32, RestDgram/binary>> when HLen>=5, 4*HLen=<DgramSize ->
;;         OptsLen = 4*(HLen - ?IP_MIN_HDR_LEN),
;;         <<Opts:OptsLen/binary,Data/binary>> = RestDgram,
;;     ...
;; end.
;;
;; Translated into the syntax defined in this file:
;;
;; (define IP-VERSION 4)
;; (define IP-MINIMUM-HEADER-LENGTH 5)
;; (bit-string-case datagram
;;   [( (= IP-VERSION :bits 4)
;;      (? header-length :bits 4)
;;      (? service-type)
;;      (? total-length :bits 16)
;;      (? id :bits 16)
;;      (? flags :bits 3)
;;      (? fragment-offset :bits 13)
;;      (? ttl)
;;      (? protocol)
;;      (? header-checksum :bits 16)
;;      (? source-ip :bits 32)
;;      (? destination-ip :bits 32)
;;      (? rest :binary) )
;;    (when (and (>= header-length 5)
;;               (>= (bit-string-length datagram) (* header-length 4))))
;;    (let ((options-length (* 4 (- header-length IP-MINIMUM-HEADER-LENGTH))))
;;      (bit-string-case rest
;;        [( (? opts :binary :bytes options-length)
;;           (? data :binary) )
;;         ...]))]
;;   ...)

;; TODO: this should probably be a match extension

(require "bitstring.rkt")

(provide bit-string-case)

(define-syntax bit-string-case
  (syntax-rules ()
    ((_ value clause ...)
     (let ((temp value))
       (when (not (bit-string? temp))
	 (error 'bit-string-case "Not a bit string: ~v" temp))
       (bit-string-case-helper temp clause ...)))))

(define-for-syntax (canonicalize-bit-string-pattern pattern-clause)
  (let loop ((pattern-clause pattern-clause)
	     (action (syntax :discard))
	     (type (syntax :integer))
	     (signedness (syntax :unsigned))
	     (endianness (syntax :big-endian))
	     (width (syntax :default)))
    (syntax-case pattern-clause (= ? :discard
				   :binary :integer :float
				   :signed :unsigned
				   :little-endian :big-endian :native-endian
				   :bytes :bits :default)
      (()
       #`(#,action #,type #,signedness #,endianness #,width))
      ((= expr rest ...)
       (loop (syntax (rest ...)) (syntax (= expr)) type signedness endianness width))
      ((? identifier rest ...)
       (loop (syntax (rest ...)) (syntax (? identifier)) type signedness endianness width))
      ((:discard rest ...)
       (loop (syntax (rest ...)) (syntax :discard) type signedness endianness width))
      ((:binary rest ...)
       (loop (syntax (rest ...)) action (syntax :binary) signedness endianness width))
      ((:integer rest ...)
       (loop (syntax (rest ...)) action (syntax :integer) signedness endianness width))
      ((:float rest ...)
       (loop (syntax (rest ...)) action (syntax :float) signedness endianness width))
      ((:signed rest ...)
       (loop (syntax (rest ...)) action type (syntax :signed) endianness width))
      ((:unsigned rest ...)
       (loop (syntax (rest ...)) action type (syntax :unsigned) endianness width))
      ((:big-endian rest ...)
       (loop (syntax (rest ...)) action type signedness (syntax :big-endian) width))
      ((:little-endian rest ...)
       (loop (syntax (rest ...)) action type signedness (syntax :little-endian) width))
      ((:native-endian rest ...)
       (loop (syntax (rest ...)) action type signedness (syntax :native-endian) width))
      ((:bytes n rest ...)
       (loop (syntax (rest ...)) action type signedness endianness (syntax (* 8 n))))
      ((:bits n rest ...)
       (loop (syntax (rest ...)) action type signedness endianness (syntax n)))
      ((:default rest ...)
       (loop (syntax (rest ...)) action type signedness endianness (syntax :default))))))

(define-syntax bit-string-case-helper
  (lambda (stx)
    (syntax-case stx (when else)
      ((_ value (else body ...))
       (syntax (begin body ...)))
      ((_ value)
       (syntax (error 'bit-string-case "No matching clauses for ~v" value)))
      ((_ value ((pattern-clause ...) body-and-guard ...) clause ...)
       (with-syntax ([tval (syntax-case (syntax (body-and-guard ...)) (when else)
			     (((when guard-exp) body ...)
			      (syntax (if guard-exp (begin body ...) (kf))))
			     ((body ...)
			      (syntax (begin body ...))))]
		     [canonical-pattern (map canonicalize-bit-string-pattern
					     (syntax->list (syntax (pattern-clause ...))))])
	 (syntax
	  (let ((kf (lambda ()
		      (bit-string-case-helper value clause ...))))
	    (bit-string-case-arm value
				 tval
				 kf
				 canonical-pattern))))))))

(define-syntax bit-string-case-arm
  (syntax-rules (= ? :discard
		 :binary :integer :float
                 :signed :unsigned
		 :little-endian :big-endian :native-endian
		 :default)
    ((_ value tval fthunk ())
     (if (zero? (bit-string-length value))
	 tval
	 (fthunk)))
    ((_ value tval fthunk (( action :binary dontcare1 dontcare2 :default ) ))
     (bit-string-perform-action action value fthunk tval))
    ((_ value tval fthunk (( action :integer dontcare1 dontcare2 :default ) remaining-clauses ...))
     (bit-string-case-arm value tval fthunk
			  (( action :integer dontcare1 dontcare2 8 ) remaining-clauses ...)))
    ((_ value tval fthunk (( action :float dontcare1 dontcare2 :default ) remaining-clauses ...))
     (bit-string-case-arm value tval fthunk
			  (( action :float dontcare1 dontcare2 64 ) remaining-clauses ...)))
    ((_ value tval fthunk (( action type signedness endianness width ) remaining-clauses ...))
     (let-values (((lhs rhs) (bit-string-split-at-or-false value width)))
       (if (not lhs)
	   (fthunk)
	   (let ((this-value (bit-string-case-extract-value lhs type signedness endianness width)))
	     (bit-string-perform-action action this-value fthunk
					(bit-string-case-arm rhs tval fthunk
							     (remaining-clauses ...)))))))))

(define-syntax bit-string-perform-action
  (syntax-rules (= ? :discard)
    ((_ (? identifier) this-value fthunk tval)
     (let ((identifier this-value))
       tval))
    ((_ (= expr) this-value fthunk tval)
     (if (equal? this-value expr)
	 tval
	 (fthunk)))
    ((_ :discard this-value fthunk tval)
     tval)))

(define-syntax bit-string-case-extract-value
  (syntax-rules (:binary :integer :float
                 :signed :unsigned
		 :little-endian :big-endian :native-endian)
    ((_ bin :binary dontcare1 dontcare2 width-in-bits)
     ;; The width is already correct from the action of bit-string-split-at-or-false.
     bin)
    ((_ bin :float dontcare1 endianness 32)
     (floating-point-bytes->real (bit-string->bytes bin)
				 (bit-string-case-endianness endianness)
				 0 4))
    ((_ bin :float dontcare1 endianness 64)
     (floating-point-bytes->real (bit-string->bytes bin)
				 (bit-string-case-endianness endianness)
				 0 8))
    ((_ bin :integer signedness endianness width-in-bits)
     ;; The width is already correct from the action of bit-string-split-at-or-false.
     (bit-string->integer bin
			  (bit-string-case-endianness endianness)
			  (bit-string-case-signedness signedness)))))

(define-syntax bit-string-case-endianness
  (syntax-rules (:little-endian :big-endian :native-endian)
    ((_ :little-endian)
     #f)
    ((_ :big-endian)
     #t)
    ((_ :native-endian)
     (system-big-endian?))))

(define-syntax bit-string-case-signedness
  (syntax-rules (:signed :unsigned)
    ((_ :unsigned)
     #f)
    ((_ :signed)
     #t)))
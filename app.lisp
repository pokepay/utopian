(in-package #:cl-user)
(defpackage utopian/app
  (:use #:cl)
  (:import-from #:utopian/project
                #:package-system
                #:project-name
                #:*project-root*
                #:*project-name*)
  (:import-from #:caveman2
                #:<app>
                #:*request*
                #:*response*
                #:*session*
                #:http-exception
                #:*exception-class*
                #:throw-code
                #:on-exception
                #:redirect
                #:clear-routing-rules)
  (:import-from #:ningle)
  (:import-from #:myway
                #:make-mapper
                #:next-route
                #:dispatch)
  (:import-from #:lack.component
                #:call)
  (:import-from #:lack.request
                #:request-path-info)
  (:import-from #:cl-annot
                #:defannotation)
  (:import-from #:cl-annot.util
                #:definition-form-type
                #:definition-form-symbol
                #:progn-form-last)
  (:import-from #:djula
                #:add-template-directory)
  (:import-from #:cl-ppcre)
  (:export #:base-app
           #:app-root
           #:app-path
           #:app-name
           #:app-exception-class
           #:route
           #:mount
           #:redirect-to
           #:*action*

           ;; from MyWay
           #:next-route

           ;; from Caveman2
           #:clear-routing-rules
           #:*request*
           #:*response*
           #:*session*
           #:http-exception
           #:on-exception
           #:throw-code))
(in-package #:utopian/app)

(defvar *package-app* (make-hash-table :test 'eq))

(defclass base-app (<app>)
  ((root :initarg :root
         :initform (asdf:component-pathname (package-system *package*))
         :accessor app-root)
   (name :initarg :name
         :initform (project-name)
         :accessor app-name)
   (exception-class :initarg :exception-class
                    :initform 'http-exception
                    :accessor app-exception-class)))

(defun app-path (app path)
  (merge-pathnames path (app-root app)))

(defmethod initialize-instance :after ((app base-app) &rest initargs)
  (declare (ignore initargs))
  (djula:add-template-directory
   (merge-pathnames #P"views/" (app-root app)))
  (setf (gethash *package* *package-app*) app)
  (setf *project-root* (app-root app))
  (setf *project-name* (app-name app)))

(defun find-controller-package (app-name name)
  (let* ((package-name (format nil "~(~A~)/controllers/~(~A~)"
                               app-name
                               name))
         (controller (asdf:find-system package-name nil)))
    (when controller
      (asdf:load-system controller)
      (find-package (string-upcase package-name)))))

(defvar *action*)

(defun %route (method url fn &key regexp identifier)
  (when (stringp fn)
    (destructuring-bind (controller action)
        (ppcre:split "::?" fn)
      (let ((package (find-controller-package (ppcre:scan-to-strings "^[^/]+" (package-name *package*))
                                              controller)))
        (unless package
          (error "Unknown package: ~A" controller))
        (multiple-value-bind (controller status)
            (intern (string-upcase action) package)
          (unless (fboundp controller)
            (error "Controller is not defined: ~S" controller))
          (unless (eq status :external)
            (warn "Controller is an internal function: ~S" controller))
          (setf fn controller
                identifier controller)))))
  (let* ((app (gethash *package* *package-app*))
         (exception-class (app-exception-class app)))
    (setf (ningle:route app url
                        :method method :regexp regexp :identifier identifier)
          (lambda (params)
            (let ((*action* identifier)
                  (*exception-class* exception-class))
              (funcall fn (caveman2.nested-parameter:parse-parameters params)))))))

(defun canonicalize-method (method)
  (etypecase method
    (list (mapcar #'canonicalize-method method))
    (keyword method)
    (symbol (intern (symbol-name method) :keyword))))

(defannotation route (method routing-rule form)
    (:arity 3)
  (let* ((last-form (progn-form-last form))
         (type (definition-form-type last-form))
         (symbol (definition-form-symbol last-form))
         (method (canonicalize-method method)))
    (case type
      (cl:lambda
          `(%route ',method ,routing-rule ,form))
      (cl:defun
          `(progn
             (%route ',method ,routing-rule ,form :identifier ',symbol)
             ',symbol))
      ('nil
       `(%route ,method ,routing-rule ,form)))))

(defun mount (mount-path controller)
  (check-type controller string)
  ;; Ensure the mount-path ends with "/".
  (setf mount-path
        (ppcre:regex-replace "/?$" mount-path "/"))
  (let ((package (find-controller-package (app-name (gethash *package* *package-app*)) controller)))
    (unless package
      (error "Unknown controller: ~A" controller))

    (%route :any (format nil "~A*" mount-path)
            (lambda (params)
              (let ((path-info (request-path-info *request*)))
                (cond
                  ((string= path-info mount-path)
                   (setf (request-path-info *request*) "/")
                   (call (gethash package *package-app*) params))
                  ((and (< (length mount-path)
                           (length path-info))
                        (string= path-info mount-path :end1 (length mount-path)))
                   (setf (request-path-info *request*)
                         (subseq path-info (length mount-path)))
                   (call (gethash package *package-app*) params))
                  (t
                   (throw-code 404))))))))

;; Rename the name of 'redirect' to 'redirect-to'
(setf (fdefinition 'redirect-to) #'caveman2:redirect)

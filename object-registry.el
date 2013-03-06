;;; object-registry.el --- track data items by various instance slots

;; Copyright (C) 2012-2013  Jonas Bernoulli

;; Author: Jonas Bernoulli <jonas@bernoul.li>
;; Created: 20120118
;; Version: 1.2.0
;; Package-Requires: ((cl-lib "0.2"))
;; Homepage: https://github.com/tarsius/object-registry
;; Keywords: data, OO

;; This file is not part of GNU Emacs.

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Track data items by various instance slots.

;; This library builds on standard library `registry.el', extending it
;; with the ability to track EIEIO objects.

;; WARNING: This version (1.2.*) is only useful to convert from a
;; registry created with version <= 1.1.* to one suitable for version
;; 2.*.*.

;; 1.1.* stores the constructor of each data object in it's own file.
;; 2.*.* will store all data objects and the tracker in the same file.
;; It will also store object vectors instead of constructors.  This
;; makes it much faster to load and save the registry.  But it also
;; makes it harder to modify the classes of the data object.

;;; Code:

(eval-when-compile
  (require 'cl-lib))

(require 'eieio)
(require 'eieio-base)
(require 'registry)

(defclass object-registry-obj () () :abstract t)

(defmethod object-registry-obj-file ((this object-registry-obj) db)
  (expand-file-name (object-name-string this)
                    (oref db :objects-directory)))

(defun object-registry-obj-read (filename)
  (let (ret (buf (get-buffer-create " *tmp registry object read*")))
    (unwind-protect
        (save-excursion
          (with-current-buffer buf
            (erase-buffer)
            (insert-file-contents filename nil nil nil t)
            (setq ret (read (buffer-string))))
          (unless (child-of-class-p (car ret) 'object-registry-obj)
            (error "Corrupt object on disk"))
          (setq ret (eval ret)))
      (kill-buffer buf))
    ret))

(defmethod object-registry-obj-save ((this object-registry-obj) db)
  (let ((buf (get-buffer-create " *tmp registry object save*")))
    (unwind-protect
        (save-excursion
          (with-current-buffer buf
            (erase-buffer)
            (let ((standard-output buf))
              (object-write this))
            (let ((backup-inhibit t)
                  (cs (car (find-coding-systems-region
                            (point-min) (point-max)))))
              (unless (eq cs 'undecided)
                (setq buffer-file-coding-system cs))
              (write-region (point-min) (point-max)
                            (object-registry-obj-file this db)
                            nil 1)))
        (kill-buffer buf)))))

(defmethod object-registry-obj-slot-exists-p ((this object-registry-obj) slot)
  (slot-exists-p this slot))

(defmethod registry-field-values ((this object-registry-obj) key db)
  (when (object-registry-obj-slot-exists-p this key)
    (let ((val (slot-value this key)))
      (if (member key (oref db tracked-atomic)) (list val) val))))

(defclass object-registry-db (registry-db)
  ((objects-directory
        :initarg :objects-directory)
   (object-file-regexp
        :initform "^[^.]"
        :initarg :object-file-regexp)
   (objects-file
        :initarg :objects-file)
   (tracker-file
        :initarg :tracker-file)
   (tracked-atomic
        :allocation :class)
   (tracked-sort
        :allocation :class
        :initform nil)))

(defmethod registry-delete ((db object-registry-db) keys assert &rest spec)
  (let* ((data (oref db :data))
         (keys (or keys
                   (apply 'registry-search db spec)))
         (tracked (oref db :tracked)))

    (dolist (key keys)
      (let ((entry (gethash key data))
            file)
        (when assert
          (cl-assert entry nil
                     "Key %s does not exists in database" key))
        (when entry
          (dolist (tr tracked)
            (when (registry-lookup-secondary db tr)
              (dolist (val (registry-field-values entry tr db))
                (let* ((value-keys (registry-lookup-secondary-value
                                    db tr val)))
                  (when (member key value-keys)
                    (registry-lookup-secondary-value
                     db tr val
                     (or (delete key value-keys) t)))))))
          (remhash key data)
          (when (slot-boundp db :objects-directory)
            (setq file (object-registry-obj-file entry db))
            (when file
              (delete-file file)))
          (when (slot-boundp db :objects-file)
            (object-registry-save-objects db)))))
    keys))

(defmethod registry-insert ((db object-registry-db) key entry)
  (puthash key entry (oref db :data))
  (dolist (tr (oref db :tracked))
    (dolist (val (registry-field-values entry tr db))
      (let* ((value-keys (registry-lookup-secondary-value db tr val)))
        (cl-pushnew key value-keys :test 'equal)
        (registry-lookup-secondary-value db tr val value-keys))))
  (when (slot-boundp db :objects-directory)
    (object-registry-obj-save entry db))
  (when (slot-boundp db :objects-file)
    (object-registry-save-objects db))
  entry)

(defmethod registry-reindex ((db object-registry-db))
  (let ((count 0)
        (expected (* (length (oref db :tracked)) (registry-size db))))
    (dolist (tr (oref db :tracked))
      (let (values)
        (maphash
         (lambda (key v)
           (cl-incf count)
           (when (and (< 0 expected)
                      (= 0 (mod count 1000)))
             (message "reindexing: %d of %d (%.2f%%)"
                      count expected (/ (* 100 count) expected)))
           (dolist (val (registry-field-values v tr db))
             (let* ((value-keys (registry-lookup-secondary-value db tr val)))
               (push key value-keys)
               (registry-lookup-secondary-value db tr val value-keys))))
         (oref db :data))))))

(defmethod object-registry-reindex ((db object-registry-db))
  (oset db tracker (make-hash-table :size 100 :rehash-size 2.0))
  (registry-reindex db)
  (object-registry-save db))

(defmethod registry-lookup-secondary-value ((db object-registry-db) tracksym val
                                            &optional set)
  (let ((h (registry-lookup-secondary db tracksym)))
    (when set
      (unless h
        (setq h (registry-lookup-secondary db tracksym t)))
      (if (eq set t)
          (remhash val h)
        (let ((s (cdr (assq tracksym (oref db tracked-sort)))))
          (puthash val (if s
                           (funcall s val set)
                         (sort set 'string<))
                   h))))
    (when h
      (gethash val h))))

(defmethod object-registry-load ((db object-registry-db)
                                 &optional msg restore)
  (when (slot-boundp db :tracker-file)
    (with-temp-buffer
      (insert-file-contents (oref db :tracker-file))
      (oset db :tracker (eval (read (buffer-string))))))
  (if (and (not restore)
           (slot-boundp db :objects-file)
           (file-exists-p (oref db objects-file)))
      (object-registry-load-cache db)
    (object-registry-load-files db msg)))

(defun object-registry-restore-obj (obj)
  (vconcat (mapcar (lambda (val)
                     (cond ((eq val 'unbound)
                            eieio-unbound)
                           ((eieio-object-p val)
                            (object-registry-restore-obj val))
                           (t
                            val)))
                   obj)))

(defmethod object-registry-load-cache ((db object-registry-db))
  (with-temp-buffer
    (insert-file-contents (oref db :objects-file))
    (let ((data (eval (read (buffer-string)))))
      (maphash (lambda (key val)
                 (puthash key (object-registry-restore-obj val) data))
               data)
      (oset db :data data))))

(defmethod object-registry-load-files ((db object-registry-db)
                                       &optional msg)
  (let* ((files (directory-files (oref db :objects-directory) t
                                 (oref db :object-file-regexp)))
         (reporter (make-progress-reporter (or msg "Loading registry...")
                                           0 (length files)))
         (idx 0))
    (dolist (file files)
      (object-registry-load-obj db file)
      (progress-reporter-update reporter (cl-incf idx)))
    (when (slot-boundp db :tracker-file)
      (with-temp-buffer
        (insert-file-contents (oref db :tracker-file))
        (oset db :tracker (eval (read (buffer-string))))))
    (progress-reporter-done reporter)))

(defmethod object-registry-load-obj ((db object-registry-db) file)
  (puthash (intern (file-name-nondirectory file))
           (object-registry-obj-read file)
           (oref db :data)))

(defmethod object-registry-save ((db object-registry-db))
  (when (slot-boundp db :objects-directory)
    (maphash (lambda (_ entry)
               (object-registry-obj-save entry db))
             (oref db :data)))
  (when (slot-boundp db :objects-file)
    (object-registry-save-objects db))
  (when (slot-boundp db :tracker-file)
    (object-registry-save-tracker db)))

(defmethod object-registry-save-objects ((db object-registry-db))
  (with-temp-file (oref db :objects-file)
    (let ((standard-output (current-buffer)))
      (object-registry-hash-table-prin1 (oref db data)))))

(defmethod object-registry-save-tracker ((db object-registry-db))
  (with-temp-file (oref db :tracker-file)
    (let ((standard-output (current-buffer)))
      (object-registry-hash-table-prin1 (oref db tracker)))))

(defun object-registry-hash-table-prin1 (hash-table)
  (princ
   (format
    "#s(hash-table size %s test %s rehash-size %s rehash-threshold %s data ("
    (hash-table-size hash-table)
    (hash-table-test hash-table)
    (hash-table-rehash-size hash-table)
    (hash-table-rehash-threshold hash-table)))
  (let* ((eieio-print-depth (1+ eieio-print-depth))
         (ws (make-string (* eieio-print-depth 2) ? ))
         alist)
    (maphash (lambda (key val) (push (list key val) alist)) hash-table)
    (dolist (elt (sort (nreverse alist)
                       (lambda (a b)
                         (string< (if (listp (car a)) (caar a) (car a))
                                  (if (listp (car b)) (caar b) (car b))))))
      (princ "\n")
      (cl-destructuring-bind (key val) elt
        (princ ws)
        (prin1 key)
        (princ " ")
        (if (hash-table-p val)
            (object-registry-hash-table-prin1 val)
          (prin1 val)))))
  (princ "))")
  (when (= eieio-print-depth 0)
    (princ "\n")))

(provide 'object-registry)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; object-registry.el ends here

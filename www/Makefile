all: ruby-cvs.html ruby-cvs.png

ruby-cvs.html: ../lib/cvs.rb
	rd2 $< > $@

ruby-cvs.png: ruby-cvs.xcf

XVFB_DISPLAY=:4

ifndef DISPLAY
USE_XVFB=yes
endif

%.png: %.xcf
ifdef USE_XVFB
	Xvfb $(XVFB_DISPLAY)& pid=$$!;\
	DISPLAY=$(XVFB_DISPLAY); export DISPLAY; \
	gimp --no-interface --console-messages -b '\
	  (let* ((in "$<") (out "$@")\
		 (im (car (gimp-xcf-load 1 in in)))\
		 (dr (car (gimp-image-flatten im))))\
	    (file-png-save 1 im dr out out 0 9 0 0 0 0 0)\
	    (gimp-quit 0))';\
	kill $$pid; \
	test -s $@
else
	gimp --no-interface --console-messages -b '\
	  (let* ((in "$<") (out "$@")\
		 (im (car (gimp-xcf-load 1 in in)))\
		 (dr (car (gimp-image-flatten im))))\
	    (file-png-save 1 im dr out out 0 9 0 0 0 0 0)\
	    (gimp-quit 0))';\
	test -s $@
endif


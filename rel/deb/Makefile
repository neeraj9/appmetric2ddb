VERSION = $(BUILD_NUMBER) # THis does not seem to work at the moment
VERSION ?= 0
COMPONENT = appmetric2ddb

.PHONY: prepare package

prepare:
	mkdir -p stage/data/appmetric2ddb
	#mkdir -p stage/data/appmetric2ddb/example
	mkdir -p stage/etc/systemd/system
	mkdir -p stage/usr/bin
	mkdir -p stage/usr/lib/appmetric2ddb/lib
	mkdir -p stage/usr/share/appmetric2ddb
	mkdir -p stage/var/lib/appmetric2ddb
	mkdir -p stage/var/log/appmetric2ddb
	mkdir -p stage/DEBIAN
	cp -r ../../_build/deb/rel/appmetric2ddb/bin stage/usr/lib/appmetric2ddb/
	cp -r ../../_build/deb/rel/appmetric2ddb/etc stage/data/appmetric2ddb/etc/
	cp -r ../../_build/deb/rel/appmetric2ddb/erts-* stage/usr/lib/appmetric2ddb/
	tar -cC ../../_build/deb/rel/appmetric2ddb/lib --exclude c_src --exclude src . | tar -xC stage/usr/lib/appmetric2ddb/lib
	cp -r ../../_build/deb/rel/appmetric2ddb/releases stage/usr/lib/appmetric2ddb/
	cp -r ../../_build/deb/rel/appmetric2ddb/share stage/usr/lib/appmetric2ddb/
	#cp -r ../../example/*conf stage/data/appmetric2ddb/example/
	cp -r systemd/appmetric2ddb.service stage/etc/systemd/system/appmetric2ddb.service
	cp control stage/DEBIAN/	
	cp preinst stage/DEBIAN/
	cp postinst stage/DEBIAN/
	chmod 555 stage/DEBIAN/preinst
	chmod 555 stage/DEBIAN/postinst

package:
	dpkg-deb --build stage appmetric2ddb.deb

clean:
	rm -rf ./stage
	rm -f *.deb

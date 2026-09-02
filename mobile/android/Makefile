.PHONY: doctor init init-damage init-ecai web build build-damage build-ecai \
        install-damage install-ecai run-damage run-ecai clean

doctor:
	@./scripts/doctor.sh

init: init-damage init-ecai

init-damage:
	$(MAKE) -C damage init DEVICE_SERIAL="$(DEVICE_SERIAL)"

init-ecai:
	$(MAKE) -C ecai init DEVICE_SERIAL="$(DEVICE_SERIAL)"

web:
	$(MAKE) -C damage web
	$(MAKE) -C ecai web

build: build-damage build-ecai

build-damage:
	$(MAKE) -C damage build DEVICE_SERIAL="$(DEVICE_SERIAL)"

build-ecai:
	$(MAKE) -C ecai build DEVICE_SERIAL="$(DEVICE_SERIAL)"

install-damage:
	$(MAKE) -C damage install DEVICE_SERIAL="$(DEVICE_SERIAL)"

install-ecai:
	$(MAKE) -C ecai install DEVICE_SERIAL="$(DEVICE_SERIAL)"

run-damage:
	$(MAKE) -C damage run DEVICE_SERIAL="$(DEVICE_SERIAL)"

run-ecai:
	$(MAKE) -C ecai run DEVICE_SERIAL="$(DEVICE_SERIAL)"

clean:
	$(MAKE) -C damage clean
	$(MAKE) -C ecai clean

CC?=		gcc
CFLAGS+=	-Wall -Wextra

CPPFLAGS+=	`pkg-config --cflags rpm`
LDFLAGS+=	`pkg-config --libs rpm`

all: helpers/rpmcat/rpmcat

helpers/rpmcat/rpmcat: helpers/rpmcat/rpmcat.c
	${CC} helpers/rpmcat/rpmcat.c -o helpers/rpmcat/rpmcat ${CFLAGS} ${CPPFLAGS} ${LDFLAGS}

clean:
	rm helpers/rpmcat/rpmcat

test::
	python3 -m unittest discover

profile-dump::
	python3 -m cProfile -o _profile ./repology-dump.py --stream >/dev/null 2>&1
	python3 -c 'import pstats; stats = pstats.Stats("_profile"); stats.sort_stats("time"); stats.print_stats()' | less

profile-reparse::
	python3 -m cProfile -o _profile ./repology-update.py -P >/dev/null 2>&1
	python3 -c 'import pstats; stats = pstats.Stats("_profile"); stats.sort_stats("time"); stats.print_stats()' | less

check:
	kwalify -lf schemas/rules.yaml rules.yaml | tee kwalify.log
	@if grep -q INVALID kwalify.log; then \
		echo "Validation failed"; \
		rm -f kwalify.log; \
		false; \
	else \
		rm -f kwalify.log; \
	fi

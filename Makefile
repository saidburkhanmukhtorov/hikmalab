.PHONY: local

# Run local Makefile commands (personal, not tracked by git)
# Usage: make local cmd=task | make local cmd=run p="prompt"
local:
ifdef cmd
	@make -f Makefile.local $(cmd) p="$(p)" n="$(n)"
else
	@make -f Makefile.local help
endif

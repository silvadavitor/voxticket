package envelope

import (
	"bytes"
	"io/fs"
	"os"
	"path/filepath"
	"testing"
)

// Os schemas embutidos precisam ser iguais aos de contracts/ (fonte da verdade).
func TestContratosEmDia(t *testing.T) {
	source := filepath.Join("..", "..", "..", "..", "contracts", "schemas")
	if _, err := os.Stat(source); err != nil {
		t.Skip("fora do repositório (ex.: build do Docker)")
	}
	files, _ := fs.Glob(contracts, "contracts/*.json")
	for _, f := range files {
		embedded, _ := contracts.ReadFile(f)
		original, err := os.ReadFile(filepath.Join(source, filepath.Base(f)))
		if err != nil || !bytes.Equal(embedded, original) {
			t.Errorf("%s desatualizado: rode scripts/sync-contracts.sh", filepath.Base(f))
		}
	}
}

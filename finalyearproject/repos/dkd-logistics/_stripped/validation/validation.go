package validation

import "fmt"

// Validate fails fast on boundary input (EF C7: never coerce invalid input).
func Required(field, value string) error {
	if value == "" {
		return fmt.Errorf("%s is required", field)
	}
	return nil
}

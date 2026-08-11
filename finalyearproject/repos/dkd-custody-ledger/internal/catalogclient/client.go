// Package catalogclient enforces the R7 master-data precondition: a passport may only be
// initialized for a GPID that Catalog says is PUBLISHED. Wire protocol: Catalog's REST read
// surface — a documented substitution until the catalog gRPC OHS lands (proto NEEDS-INFO);
// swap behind this interface. Unset base URL = precondition skipped with a warning.
package catalogclient

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"
)

type Client struct {
	base string
	hc   *http.Client
}

func New(baseURL string) *Client {
	return &Client{base: strings.TrimRight(baseURL, "/"), hc: &http.Client{Timeout: 5 * time.Second}}
}

func (c *Client) Enabled() bool { return c != nil && c.base != "" }

// GPIDPublished reports whether Catalog knows the GPID and it is PUBLISHED.
func (c *Client) GPIDPublished(ctx context.Context, gpid string) (bool, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet,
		c.base+"/v1/catalog/products/"+url.PathEscape(gpid), nil)
	if err != nil {
		return false, fmt.Errorf("catalogclient: request: %w", err)
	}
	resp, err := c.hc.Do(req)
	if err != nil {
		return false, fmt.Errorf("catalogclient: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return false, nil
	}
	if resp.StatusCode != http.StatusOK {
		return false, fmt.Errorf("catalogclient: status %d", resp.StatusCode)
	}
	var env struct {
		Data struct {
			Status string `json:"status"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&env); err != nil {
		return false, fmt.Errorf("catalogclient: decode: %w", err)
	}
	return env.Data.Status == "PUBLISHED", nil
}

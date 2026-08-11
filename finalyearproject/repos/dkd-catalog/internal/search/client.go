// Package search talks to OpenSearch — the ONLY sanctioned business-search engine
// (never the observability Elasticsearch). Plain HTTP, no extra dependencies.
// Index naming is NEEDS-INFO in canon, so the index is configurable (default catalog-products).
package search

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

type Client struct {
	base  string
	index string
	hc    *http.Client
}

func New(baseURL, index string) *Client {
	return &Client{
		base:  strings.TrimRight(baseURL, "/"),
		index: index,
		hc:    &http.Client{Timeout: 10 * time.Second},
	}
}

// Enabled reports whether a search backend is configured.
func (c *Client) Enabled() bool { return c != nil && c.base != "" }

func (c *Client) do(ctx context.Context, method, path string, body any) (*http.Response, error) {
	var rd io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return nil, fmt.Errorf("search: marshal: %w", err)
		}
		rd = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, c.base+path, rd)
	if err != nil {
		return nil, fmt.Errorf("search: request: %w", err)
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := c.hc.Do(req)
	if err != nil {
		return nil, fmt.Errorf("search: %s %s: %w", method, path, err)
	}
	return resp, nil
}

func (c *Client) Ping(ctx context.Context) error {
	resp, err := c.do(ctx, http.MethodGet, "/", nil)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return fmt.Errorf("search: ping status %d", resp.StatusCode)
	}
	return nil
}

// IndexProduct upserts the product document keyed by GPID.
func (c *Client) IndexProduct(ctx context.Context, gpid string, doc map[string]any) error {
	resp, err := c.do(ctx, http.MethodPut,
		fmt.Sprintf("/%s/_doc/%s", c.index, url.PathEscape(gpid)), doc)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return fmt.Errorf("search: index %s: status %d: %s", gpid, resp.StatusCode, b)
	}
	return nil
}

func (c *Client) DeleteProduct(ctx context.Context, gpid string) error {
	resp, err := c.do(ctx, http.MethodDelete,
		fmt.Sprintf("/%s/_doc/%s", c.index, url.PathEscape(gpid)), nil)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 && resp.StatusCode != http.StatusNotFound {
		return fmt.Errorf("search: delete %s: status %d", gpid, resp.StatusCode)
	}
	return nil
}

// Search runs a multi-field match over the Bangla-first name fields and category path.
func (c *Client) Search(ctx context.Context, q string, limit int) ([]map[string]any, error) {
	if limit <= 0 || limit > 100 {
		limit = 20
	}
	body := map[string]any{
		"size": limit,
		"query": map[string]any{
			"multi_match": map[string]any{
				"query":  q,
				"fields": []string{"namesBn", "namesEn", "categoryPath"},
			},
		},
	}
	resp, err := c.do(ctx, http.MethodPost, "/"+c.index+"/_search", body)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return nil, fmt.Errorf("search: query status %d: %s", resp.StatusCode, b)
	}
	var out struct {
		Hits struct {
			Hits []struct {
				Source map[string]any `json:"_source"`
			} `json:"hits"`
		} `json:"hits"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, fmt.Errorf("search: decode: %w", err)
	}
	docs := make([]map[string]any, 0, len(out.Hits.Hits))
	for _, h := range out.Hits.Hits {
		docs = append(docs, h.Source)
	}
	return docs, nil
}

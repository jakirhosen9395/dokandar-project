package app

import (
	"encoding/json"
	"fmt"
	"net/http"
)

// OpenAPISpec returns an OpenAPI 3.0.3 document rich enough that the Swagger UI
// "Try it out" panel is fully usable: every route is present with its correct
// HTTP verb, path parameters carry working examples, and each write endpoint
// carries a pre-filled request-body example (the address example uses a real
// seeded BD geo chain, so it returns 201 out of the box). Auth-protected ops
// declare the HTTPBearer scheme so the Authorize button gates them.
func OpenAPISpec(serviceName, codeVersion, envVersion, tenant, env string) []byte {
	desc := fmt.Sprintf(
		"**service_name**: `%s` &nbsp;|&nbsp; **code_version**: `%s` &nbsp;|&nbsp; **env_version**: `%s` &nbsp;|&nbsp; **tenant**: `%s` &nbsp;|&nbsp; **env**: `%s`\n\n"+
			"### How to test\n"+
			"1. Click **Authorize** and paste a Bearer **access token** from the auth service "+
			"(`POST /api/v1/auth/login/request` → `/login/verify`, or `/signup/verify`). The `/geo/*` "+
			"endpoints are **public** (no token).\n"+
			"2. The request bodies below are pre-filled with working examples — the address example uses a "+
			"real seeded geo chain (`barisal → barisal → barisal-sadar → barisal-1`). Discover other codes "+
			"via the `/geo/*` endpoints.\n"+
			"3. Your profile row is created when auth's `UserCreated` event is consumed; if `/me` returns "+
			"`404 profile_not_found`, sign up/login through auth first.",
		serviceName, codeVersion, envVersion, tenant, env,
	)

	// ---- reusable request-body examples (media-type level → prefills the box) ----
	patchMeExample := map[string]any{
		"name_en": "Rahim Uddin", "name_bn": "রহিম উদ্দিন",
		"gender": "m", "dob": "1995-05-20", "locale": "bn",
		"whatsapp_number": "01711112222",
	}
	avatarExample := map[string]any{"media_id": "11111111-1111-4111-8111-111111111111"}
	addressCreateExample := map[string]any{
		"label": "Home", "recipient_name": "Rahim Uddin", "recipient_phone": "01712223333",
		"division_code": "barisal", "district_code": "barisal", "upazila_code": "barisal-sadar",
		"union_code": "barisal-1", "line1": "12 Test Road, Dhanmondi", "is_default": true,
	}
	addressUpdateExample := map[string]any{"label": "Office", "recipient_phone": "01713334444"}

	sampleUUID := "11111111-1111-4111-8111-111111111111"

	doc := map[string]any{
		"openapi": "3.0.3",
		"info": map[string]any{
			"title":       "DOKANDAR Profile Service",
			"version":     codeVersion,
			"description": desc,
			"contact": map[string]any{
				"name":  "DOKANDAR Platform",
				"url":   "https://dokandar.com.bd",
				"email": "api@dokandar.com.bd",
			},
			"license": map[string]any{"name": "Proprietary"},
		},
		"servers": []map[string]any{
			{"url": "https://api.dokandar.com.bd", "description": "prod"},
			{"url": "http://localhost:10002", "description": "local"},
		},
		"components": map[string]any{
			"securitySchemes": map[string]any{
				"HTTPBearer":    map[string]any{"type": "http", "scheme": "bearer", "bearerFormat": "JWT"},
				"internalToken": map[string]any{"type": "apiKey", "in": "header", "name": "x-internal-token"},
			},
			"schemas": map[string]any{
				"PatchMeRequest":        patchMeSchema(),
				"AvatarRequest":         avatarSchema(),
				"AddressCreateRequest":  addressSchema(true),
				"AddressUpdateRequest":  addressSchema(false),
				"ErrorEnvelope":         errorSchema(),
			},
		},
		"tags": []map[string]any{
			{"name": "ops", "description": "Operational / contract surface"},
			{"name": "geo", "description": "Public BD geo reference (no auth)"},
			{"name": "me", "description": "The authenticated user's own profile + addresses"},
			{"name": "admin", "description": "Admin / platform-staff lookups"},
		},
		"paths": map[string]any{
			// ---- ops (public) ----
			"/ready":   pub("ops", "getReady", "Readiness probe (gating deps)", nil, nil, ok("200", "ready")),
			"/health":  pub("ops", "getHealth", "Full health + dependency checks", nil, nil, ok("200", "healthy")),
			"/data":    pub("ops", "getData", "Tenant host/infra snapshot (data/<tenant>/collect.sh)", nil, nil, ok("200", "snapshot")),
			"/metrics": pub("ops", "getMetrics", "Prometheus metrics", nil, nil, ok("200", "exposition")),

			// ---- geo (public) ----
			"/api/v1/profile/geo/divisions": pub("geo", "listDivisions",
				"List BD divisions", nil, nil, ok("200", "{items:[...]}")),
			"/api/v1/profile/geo/divisions/{code}/districts": pub("geo", "listDistricts",
				"List districts under a division",
				[]map[string]any{codeParam("code", "barisal", "division code")}, nil,
				merge(ok("200", "{items:[...]}"), errResp("404", "division not found"))),
			"/api/v1/profile/geo/districts/{code}/upazilas": pub("geo", "listUpazilas",
				"List upazilas under a district",
				[]map[string]any{codeParam("code", "barisal", "district code")}, nil,
				merge(ok("200", "{items:[...]}"), errResp("404", "district not found"))),
			"/api/v1/profile/geo/upazilas/{code}/unions": pub("geo", "listUnions",
				"List unions under an upazila",
				[]map[string]any{codeParam("code", "barisal-sadar", "upazila code")}, nil,
				merge(ok("200", "{items:[...]}"), errResp("404", "upazila not found"))),

			// ---- me (auth) ----
			"/api/v1/profile/me": map[string]any{
				"get":   secOp("me", "getMe", "Get my profile", nil, nil, merge(ok("200", "profile"), errResp("401", "token_missing/invalid"), errResp("404", "profile_not_found"))),
				"patch": secOp("me", "patchMe", "Update my profile (partial)", nil, jbody("PatchMeRequest", patchMeExample), merge(ok("200", "updated profile"), errResp("401", "unauthorized"), errResp("422", "validation_error/invalid_request/phone_invalid"))),
				"put":   secOp("me", "putMe", "Update my profile (PUT alias; partial)", nil, jbody("PatchMeRequest", patchMeExample), merge(ok("200", "updated profile"), errResp("401", "unauthorized"), errResp("422", "validation_error"))),
			},
			"/api/v1/profile/me/avatar": map[string]any{
				"post": secOp("me", "setAvatar", "Set my avatar by media_id", nil, jbody("AvatarRequest", avatarExample), merge(ok("200", "{profile, avatar_url}"), errResp("401", "unauthorized"), errResp("422", "validation_error"))),
			},
			"/api/v1/profile/me/addresses": map[string]any{
				"get":  secOp("me", "listAddresses", "List my addresses", nil, nil, merge(ok("200", "{items:[...]}"), errResp("401", "unauthorized"))),
				"post": secOp("me", "addAddress", "Add an address", nil, jbody("AddressCreateRequest", addressCreateExample), merge(created("201", "created address"), errResp("401", "unauthorized"), errResp("422", "validation_error/phone_invalid/geo_chain_invalid"))),
			},
			"/api/v1/profile/me/addresses/{id}": map[string]any{
				"get":    secOp("me", "getAddress", "Get one address", []map[string]any{idParam("id", sampleUUID)}, nil, merge(ok("200", "address"), errResp("400", "invalid_uuid"), errResp("401", "unauthorized"), errResp("404", "not_found"))),
				"patch":  secOp("me", "updateAddress", "Update an address (partial)", []map[string]any{idParam("id", sampleUUID)}, jbody("AddressUpdateRequest", addressUpdateExample), merge(ok("200", "updated address"), errResp("400", "invalid_uuid"), errResp("401", "unauthorized"), errResp("404", "not_found"), errResp("422", "validation_error/geo_chain_invalid"))),
				"delete": secOp("me", "deleteAddress", "Delete an address (soft)", []map[string]any{idParam("id", sampleUUID)}, nil, merge(noContent("204"), errResp("400", "invalid_uuid"), errResp("401", "unauthorized"), errResp("404", "not_found"), errResp("409", "default_in_use"))),
			},
			"/api/v1/profile/me/addresses/{id}/default": map[string]any{
				"post": secOp("me", "setDefaultAddress", "Mark an address as default", []map[string]any{idParam("id", sampleUUID)}, nil, merge(noContent("204"), errResp("400", "invalid_uuid"), errResp("401", "unauthorized"), errResp("404", "not_found"))),
			},

			// ---- admin (auth + role) ----
			"/api/v1/profile/admin/profiles/{user_id}": map[string]any{
				"get": secOp("admin", "adminGetProfile", "Read any user's profile (admin/platform_staff)", []map[string]any{idParam("user_id", sampleUUID)}, nil, merge(ok("200", "profile"), errResp("400", "invalid_uuid"), errResp("401", "unauthorized"), errResp("403", "forbidden"), errResp("404", "not_found"))),
			},
		},
	}
	b, _ := json.MarshalIndent(doc, "", "  ")
	return b
}

// ---- operation builders ----------------------------------------------------

func pub(tag, opID, summary string, params []map[string]any, body map[string]any, responses map[string]any) map[string]any {
	return map[string]any{"get": opBody(tag, opID, summary, false, params, body, responses)}
}
func secOp(tag, opID, summary string, params []map[string]any, body map[string]any, responses map[string]any) map[string]any {
	return opBody(tag, opID, summary, true, params, body, responses)
}
func opBody(tag, opID, summary string, secured bool, params []map[string]any, body map[string]any, responses map[string]any) map[string]any {
	op := map[string]any{
		"tags":        []string{tag},
		"operationId": opID,
		"summary":     summary,
		"responses":   responses,
	}
	if secured {
		op["security"] = []map[string][]string{{"HTTPBearer": {}}}
	}
	if len(params) > 0 {
		op["parameters"] = params
	}
	if body != nil {
		op["requestBody"] = body
	}
	return op
}

func jbody(schemaRef string, example any) map[string]any {
	return map[string]any{
		"required": true,
		"content": map[string]any{
			"application/json": map[string]any{
				"schema":  map[string]any{"$ref": "#/components/schemas/" + schemaRef},
				"example": example,
			},
		},
	}
}

func idParam(name, example string) map[string]any {
	return map[string]any{
		"name": name, "in": "path", "required": true,
		"description": "UUID",
		"schema":      map[string]any{"type": "string", "format": "uuid"},
		"example":     example,
	}
}
func codeParam(name, example, desc string) map[string]any {
	return map[string]any{
		"name": name, "in": "path", "required": true,
		"description": desc,
		"schema":      map[string]any{"type": "string"},
		"example":     example,
	}
}

func ok(code, desc string) map[string]any       { return map[string]any{code: map[string]any{"description": desc}} }
func created(code, desc string) map[string]any   { return map[string]any{code: map[string]any{"description": desc}} }
func noContent(code string) map[string]any       { return map[string]any{code: map[string]any{"description": "No Content"}} }
func errResp(code, desc string) map[string]any {
	return map[string]any{code: map[string]any{
		"description": desc,
		"content": map[string]any{
			"application/json": map[string]any{"schema": map[string]any{"$ref": "#/components/schemas/ErrorEnvelope"}},
		},
	}}
}
func merge(maps ...map[string]any) map[string]any {
	out := map[string]any{}
	for _, m := range maps {
		for k, v := range m {
			out[k] = v
		}
	}
	return out
}

// ---- schemas ---------------------------------------------------------------

func patchMeSchema() map[string]any {
	return map[string]any{
		"type": "object",
		"properties": map[string]any{
			"name_en":         map[string]any{"type": "string", "example": "Rahim Uddin"},
			"name_bn":         map[string]any{"type": "string", "example": "রহিম উদ্দিন"},
			"gender":          map[string]any{"type": "string", "enum": []string{"m", "f", "x", "prefer_not_say"}, "example": "m"},
			"dob":             map[string]any{"type": "string", "format": "date", "example": "1995-05-20"},
			"locale":          map[string]any{"type": "string", "enum": []string{"bn", "en"}, "example": "bn"},
			"whatsapp_number": map[string]any{"type": "string", "example": "01711112222"},
		},
	}
}
func avatarSchema() map[string]any {
	return map[string]any{
		"type":     "object",
		"required": []string{"media_id"},
		"properties": map[string]any{
			"media_id": map[string]any{"type": "string", "format": "uuid", "description": "Media object id (UUID)", "example": "11111111-1111-4111-8111-111111111111"},
		},
	}
}
func addressSchema(create bool) map[string]any {
	props := map[string]any{
		"label":           map[string]any{"type": "string", "example": "Home"},
		"recipient_name":  map[string]any{"type": "string", "example": "Rahim Uddin"},
		"recipient_phone": map[string]any{"type": "string", "description": "^01[3-9]\\d{8}$", "example": "01712223333"},
		"division_code":   map[string]any{"type": "string", "example": "barisal"},
		"district_code":   map[string]any{"type": "string", "example": "barisal"},
		"upazila_code":    map[string]any{"type": "string", "example": "barisal-sadar"},
		"union_code":      map[string]any{"type": "string", "nullable": true, "example": "barisal-1"},
		"line1":           map[string]any{"type": "string", "example": "12 Test Road, Dhanmondi"},
		"line2":           map[string]any{"type": "string", "nullable": true},
		"landmark":        map[string]any{"type": "string", "nullable": true},
		"lat":             map[string]any{"type": "number", "format": "double", "nullable": true},
		"lng":             map[string]any{"type": "number", "format": "double", "nullable": true},
		"is_default":      map[string]any{"type": "boolean", "example": true},
	}
	s := map[string]any{"type": "object", "properties": props}
	if create {
		s["required"] = []string{"label", "recipient_name", "recipient_phone", "division_code", "district_code", "upazila_code", "line1"}
	}
	return s
}
func errorSchema() map[string]any {
	return map[string]any{
		"type": "object",
		"properties": map[string]any{
			"error": map[string]any{
				"type": "object",
				"properties": map[string]any{
					"code":       map[string]any{"type": "string", "description": "stable machine code (lowercase snake_case)", "example": "validation_error"},
					"message":    map[string]any{"type": "string", "example": "request validation failed"},
					"request_id": map[string]any{"type": "string", "description": "honour-or-mint x-request-id", "example": "req_01HXYZ"},
					"details":    map[string]any{"type": "object", "additionalProperties": true, "description": "optional structured context"},
				},
			},
		},
	}
}

// ServeDocs renders the Swagger UI HTML pointing at /openapi.json.
func ServeDocs(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write([]byte(`<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8"/>
  <title>02-profile API</title>
  <link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist@5/swagger-ui.css">
</head>
<body>
  <div id="swagger-ui"></div>
  <script src="https://unpkg.com/swagger-ui-dist@5/swagger-ui-bundle.js"></script>
  <script>
    window.ui = SwaggerUIBundle({ url: "/openapi.json", dom_id: "#swagger-ui", deepLinking: true,
      tryItOutEnabled: true, persistAuthorization: true });
  </script>
</body>
</html>
`))
}

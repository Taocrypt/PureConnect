package main

import (
	"sort"
	"strings"

	"github.com/beevik/etree"
	"github.com/mythologyli/zju-connect/client"
	"github.com/mythologyli/zju-connect/client/easyconnect"
)

// WebResource is one entry of the portal's resource list (what the official
// EasyConnect app shows under 资源列表).
type WebResource struct {
	Name  string `json:"name"`
	Group string `json:"group,omitempty"`
	URL   string `json:"url,omitempty"`
	Host  string `json:"host,omitempty"`
	Type  string `json:"type,omitempty"`
}

func rawResourceList(c client.Client) string {
	if ec, ok := c.(*easyconnect.Client); ok {
		return ec.RawResources()
	}
	return ""
}

// parseWebResources is deliberately tolerant: element and attribute names
// differ between EasyConnect versions.
func parseWebResources(raw string) []WebResource {
	if strings.TrimSpace(raw) == "" {
		return nil
	}
	doc := etree.NewDocument()
	if err := doc.ReadFromString(raw); err != nil {
		return nil
	}
	groups := map[string]string{}
	groupOrder := map[string]int{}
	var rcs []*etree.Element
	var walk func(e *etree.Element)
	walk = func(e *etree.Element) {
		for _, ch := range e.ChildElements() {
			switch {
			case strings.EqualFold(ch.Tag, "Rc"):
				rcs = append(rcs, ch)
			case ch.SelectAttrValue("id", "") != "" && ch.SelectAttrValue("name", "") != "":
				id := ch.SelectAttrValue("id", "")
				if _, ok := groups[id]; !ok {
					groupOrder[ch.SelectAttrValue("name", "")] = len(groups)
				}
				groups[id] = ch.SelectAttrValue("name", "")
			}
			walk(ch)
		}
	}
	walk(&doc.Element)

	var out []WebResource
	seen := map[string]bool{}
	for _, rc := range rcs {
		name := strings.TrimSpace(rc.SelectAttrValue("name", ""))
		if name == "" {
			continue
		}
		host := strings.TrimSpace(strings.Split(rc.SelectAttrValue("host", ""), ";")[0])
		// Only a single explicit port belongs in a URL; ranges such as
		// "1~7999;8001~65535" mean "any port" for a non-web resource.
		port := strings.TrimSpace(rc.SelectAttrValue("port", ""))
		if strings.ContainsAny(port, "~;,-") {
			port = ""
		}
		svc := strings.ToUpper(rc.SelectAttrValue("svc", ""))
		url := ""
		if strings.HasPrefix(host, "http://") || strings.HasPrefix(host, "https://") {
			url = host
		} else if host != "" && !isRangeHost(host) {
			// Bare IPs / hosts (any svc) still get a link; the user decides.
			scheme := "http"
			if strings.Contains(svc, "HTTPS") || port == "443" || port == "8443" {
				scheme = "https"
			}
			url = scheme + "://" + host
			if port != "" && port != "80" && port != "443" && port != "0" {
				url += ":" + port
			}
			if p := rc.SelectAttrValue("app_path", ""); strings.HasPrefix(p, "/") {
				url += p
			}
		}
		g := groups[rc.SelectAttrValue("rc_grp_id", "")]
		key := g + "|" + name + "|" + url
		if seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, WebResource{Name: name, Group: g, URL: url, Host: host, Type: rc.SelectAttrValue("type", "")})
	}
	sort.SliceStable(out, func(i, j int) bool { return groupOrder[out[i].Group] < groupOrder[out[j].Group] })
	return out
}

func isRangeHost(h string) bool {
	if strings.ContainsAny(h, "*~/") {
		return true
	}
	return strings.Contains(h, "-") && h[0] >= '0' && h[0] <= '9'
}

//! Comparable listings from the public vinted.de search page.

use std::sync::LazyLock;
use std::time::Duration;

use anyhow::{Context, Result, bail};
use regex::Regex;
use serde_json::Value;

pub const DOMAIN: &str = "www.vinted.de";
const UA: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 \
                  (KHTML, like Gecko) Chrome/128.0 Safari/537.36";

pub struct Listing {
    pub title: String,
    pub brand: String,
    pub size: String,
    pub condition: String,
    pub price: f64,
    pub favs: u64,
    pub url: String,
}

static FLIGHT_CHUNK: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r#"(?s)self\.__next_f\.push\(\[1,"(.*?)"\]\)</script>"#).unwrap());

pub fn fetch(query: &str, order: Option<&str>) -> Result<Vec<Listing>> {
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(30)))
        .build()
        .into();
    let get = |url: &str| -> Result<String> {
        Ok(agent
            .get(url)
            .header("User-Agent", UA)
            .header("Accept-Language", "de-DE,de;q=0.9")
            .call()?
            .body_mut()
            .with_config()
            .limit(64 * 1024 * 1024)
            .read_to_string()?)
    };

    get(&format!("https://{DOMAIN}/"))?; // session cookies
    let mut params = vec![("search_text", query)];
    if let Some(order) = order {
        params.push(("order", order));
    }
    let query_string: Vec<String> = params.iter().map(|(k, v)| format!("{k}={}", encode(v))).collect();
    let html = get(&format!("https://{DOMAIN}/catalog?{}", query_string.join("&")))?;
    parse_catalog(&html)
}

/// Search results are embedded in the Next.js flight payload as escaped JS strings.
pub fn parse_catalog(html: &str) -> Result<Vec<Listing>> {
    let mut payload = String::new();
    for caps in FLIGHT_CHUNK.captures_iter(html) {
        let chunk: String = serde_json::from_str(&format!("\"{}\"", &caps[1])).context("decoding page payload")?;
        payload.push_str(&chunk);
    }
    let marker = "\"items\":{\"items\":[";
    let Some(start) = payload.find(marker) else {
        bail!("Could not find search results in Vinted page (layout changed or blocked).");
    };
    let json_start = start + "\"items\":".len();
    let data: Value = serde_json::Deserializer::from_str(&payload[json_start..])
        .into_iter::<Value>()
        .next()
        .context("no search results JSON")??;

    let items = data["items"].as_array().cloned().unwrap_or_default();
    Ok(items
        .iter()
        .map(|entry| {
            let p = &entry["productItem"];
            let item_box = &p["itemBox"];
            let second = item_box["secondLine"].as_str().unwrap_or("");
            let parts: Vec<&str> = second.split(" · ").collect();
            Listing {
                title: p["title"].as_str().unwrap_or("").to_string(),
                brand: item_box["firstLine"].as_str().unwrap_or("").to_string(),
                size: if parts.len() > 1 { parts[0].to_string() } else { String::new() },
                condition: parts.last().copied().unwrap_or("").to_string(),
                price: p["price"]["amount"].as_str().and_then(|a| a.parse().ok()).unwrap_or(0.0),
                favs: p["favouriteCount"].as_u64().unwrap_or(0),
                url: format!("https://{DOMAIN}{}", p["url"].as_str().unwrap_or("")),
            }
        })
        .collect())
}

/// Python's `statistics.quantiles(data, n)` with the default "exclusive" method.
pub fn quantiles(values: &[f64], n: usize) -> Vec<f64> {
    let mut data = values.to_vec();
    data.sort_by(|a, b| a.total_cmp(b));
    let ld = data.len();
    let m = ld + 1;
    (1..n)
        .map(|i| {
            let j = (i * m / n).clamp(1, ld - 1);
            let delta = (i * m) as f64 - (j * n) as f64;
            (data[j - 1] * (n as f64 - delta) + data[j] * delta) / n as f64
        })
        .collect()
}

fn encode(value: &str) -> String {
    value
        .bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => (b as char).to_string(),
            b' ' => "+".to_string(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quantiles_match_python() {
        // statistics.quantiles([1, 3, 3, 4, 5, 8, 17], n=4) == [3.0, 4.0, 8.0]
        assert_eq!(quantiles(&[1.0, 3.0, 3.0, 4.0, 5.0, 8.0, 17.0], 4), vec![3.0, 4.0, 8.0]);
        // statistics.quantiles([2, 2, 3, 5], n=4) == [2.0, 2.5, 4.5]
        assert_eq!(quantiles(&[2.0, 2.0, 3.0, 5.0], 4), vec![2.0, 2.5, 4.5]);
    }

    #[test]
    fn encodes_like_urlencode() {
        assert_eq!(encode("c&a jeanshemd"), "c%26a+jeanshemd");
        assert_eq!(encode("größe"), "gr%C3%B6%C3%9Fe");
    }

    #[test]
    fn parses_flight_payload() {
        let json = r#""items":{"items":[{"productItem":{"title":"Hemd","url":"/items/1-hemd","favouriteCount":3,"price":{"amount":"4.50"},"itemBox":{"firstLine":"C&A","secondLine":"M · Sehr gut"}}}]}"#;
        let escaped = serde_json::to_string(json).unwrap();
        let html = format!("<script>self.__next_f.push([1,{escaped}])</script>");
        let listings = parse_catalog(&html).unwrap();
        assert_eq!(listings.len(), 1);
        assert_eq!(listings[0].brand, "C&A");
        assert_eq!(listings[0].size, "M");
        assert_eq!(listings[0].condition, "Sehr gut");
        assert_eq!(listings[0].price, 4.5);
        assert_eq!(listings[0].url, "https://www.vinted.de/items/1-hemd");
    }
}

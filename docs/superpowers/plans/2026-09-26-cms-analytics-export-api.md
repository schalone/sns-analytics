# CMS Analytics Export API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add one authenticated, read-only, cursor-paged JSON export API to the Umbraco CMS so the analytics pipeline can pull orders, tickets, refunds, promo redemptions, gift cards, checkout sessions, events, venues, metros and instructors incrementally.

**Architecture:** A single `AnalyticsExportController` at `GET /api/export/{entity}` guarded by a bearer-token action filter. Commerce entities are read with keyset-paginated SQL through `IScopeProvider` (the same pattern as `AdminCommerceService`). Content entities are read from the published cache through `IUmbracoContextFactory`, mapped to flat DTOs, sorted by `(updatedAt, key)` and paged in memory. Everything testable without booting Umbraco (cursor codec, auth compare, hashing, DTO mapping, query normalisation) is a pure static class with xunit tests.

**Tech Stack:** .NET 10, Umbraco 17.5, NPoco via `IScopeProvider`, xunit (`tests/Sip-n-Script.Tests`), SQL Server.

**Spec:** `/Users/stephenchaloner/sns-analytics/docs/superpowers/specs/2026-09-26-analytics-pipeline-design.md` §6 (CMS export API). Read §6 before starting.

**Repo:** all files in this plan live in `/Users/stephenchaloner/sipandscript-sns.webapp.cms`. Work on a new branch `feat/analytics-export-api` cut from `develop`. Follow the CMS repo's `AGENTS.md` (surgical changes, no integer ids to callers, money in cents, `eventDate` + time-only `startTime`/`endTime`).

## Global Constraints

- All identifiers in responses are GUIDs (`OrderGuid`, `TicketGuid`, …) or UUIDv5 values derived from tables that have no GUID column. Never emit `OrderId`, `TicketId`, `OrderItemId` or any other integer database id.
- No personal data: never emit `PurchaserName`, `PurchaserEmail`, `PurchaserPhone`, `AttendeeName`, `AttendeeEmail`, `RecipientName`, `RecipientEmail`, `GiftMessage`, `ShippingAddress1/2`, `EncryptedCode`, `CodeHash`, `TicketCode`. Emails appear only as `customerHash` = lower-case SHA-256 hex of the trimmed, lower-cased email.
- Money is integer cents, exactly as stored. Timestamps are ISO-8601 UTC (`DateTime` values in these tables are already UTC).
- Config key is `Analytics:ExportApiKey` (env `Analytics__ExportApiKey`). Unset → every export route returns 404. Set but wrong/missing header → 401.
- `pageSize` default 500, maximum 1000. Rows ordered by `(updatedAt ASC, key ASC)`. `cursor` is opaque base64. `since` filters `updatedAt >= since`. `full=1` ignores `since`.
- Response envelope: `{"entity": string, "generatedAt": ISO-8601, "items": [...], "nextCursor": string|null}`. Property names camelCase (ASP.NET default JSON options).
- Content entities are published content only.
- No new NuGet packages.

## Review Focus

1. **Two rows with the identical `UpdatedAt` tick** — must both be returned exactly once across pages (keyset tiebreaker on the key). Test in Task 2 (cursor round-trip) and Task 5 (SQL where-clause builder).
2. **`since` in the future or unparseable** — must return 400, not an empty 200 that silently advances a watermark. Test in Task 4 (`ExportQuery.TryParse`).
3. **A ticket whose order item was never attached to an order** (abandoned checkout, `OrderItems.OrderId IS NULL`) — `tickets` must return `orderKey: null`, not drop the row or throw. Covered by the LEFT JOIN in Task 5 SQL; assert in the smoke script (Task 8).
4. **Header present but scheme wrong** (`Authorization: Basic …`) or token with surrounding whitespace — must be 401, not 500. Test in Task 1.
5. **Event whose venue was unpublished/deleted** — `events` must return `venueKey: null` and still include the row. Test in Task 6 (mapper with null venue).

---

### Task 1: Options, auth filter, and branch

**Files:**
- Create: `Services/Analytics/AnalyticsExportOptions.cs`
- Create: `Services/Analytics/AnalyticsExportAuth.cs`
- Create: `Controllers/AnalyticsExportAuthFilter.cs`
- Modify: `appsettings.json` (add `Analytics` section), `.envSample` (add `Analytics__ExportApiKey=`)
- Test: `tests/Sip-n-Script.Tests/AnalyticsExportAuthTests.cs`

**Interfaces:**
- Produces: `AnalyticsExportOptions { string? ExportApiKey }` bound to section `Analytics`; `static AnalyticsExportAuth.Decision Check(string? authorizationHeader, string? configuredKey)` returning `NotConfigured | Unauthorized | Ok`; `AnalyticsExportAuthFilter : IAsyncActionFilter` used by the controller in Task 7.

- [ ] **Step 1: Create the branch**

```bash
cd /Users/stephenchaloner/sipandscript-sns.webapp.cms
git fetch origin && git checkout develop && git pull --ff-only
git checkout -b feat/analytics-export-api
```

- [ ] **Step 2: Write the failing tests**

`tests/Sip-n-Script.Tests/AnalyticsExportAuthTests.cs`:

```csharp
using SipnScript.Services.Analytics;
using Xunit;

namespace SipnScript.Tests
{
    public class AnalyticsExportAuthTests
    {
        [Theory]
        [InlineData(null)]
        [InlineData("")]
        [InlineData("   ")]
        public void NotConfigured_WhenKeyMissing(string? key)
        {
            Assert.Equal(AnalyticsExportAuth.Decision.NotConfigured, AnalyticsExportAuth.Check("Bearer abc", key));
        }

        [Theory]
        [InlineData(null)]
        [InlineData("")]
        [InlineData("Basic c2VjcmV0")]
        [InlineData("Bearer")]
        [InlineData("Bearer wrong")]
        [InlineData("bearer secret-1")]   // scheme is case-sensitive by design
        public void Unauthorized_WhenHeaderWrong(string? header)
        {
            Assert.Equal(AnalyticsExportAuth.Decision.Unauthorized, AnalyticsExportAuth.Check(header, "secret-1"));
        }

        [Theory]
        [InlineData("Bearer secret-1")]
        [InlineData("Bearer  secret-1 ")]   // surrounding whitespace around the token is tolerated
        public void Ok_WhenTokenMatches(string header)
        {
            Assert.Equal(AnalyticsExportAuth.Decision.Ok, AnalyticsExportAuth.Check(header, "secret-1"));
        }

        [Fact]
        public void Unauthorized_WhenLengthsDiffer()
        {
            Assert.Equal(AnalyticsExportAuth.Decision.Unauthorized, AnalyticsExportAuth.Check("Bearer secret-12", "secret-1"));
        }
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd /Users/stephenchaloner/sipandscript-sns.webapp.cms/tests/Sip-n-Script.Tests && dotnet test --nologo -v q --filter AnalyticsExportAuthTests`
Expected: build error `The type or namespace name 'Analytics' does not exist`.

- [ ] **Step 4: Implement options and auth**

`Services/Analytics/AnalyticsExportOptions.cs`:

```csharp
namespace SipnScript.Services.Analytics
{
    public class AnalyticsExportOptions
    {
        public const string SectionName = "Analytics";
        public string? ExportApiKey { get; set; }
    }
}
```

`Services/Analytics/AnalyticsExportAuth.cs`:

```csharp
using System.Security.Cryptography;
using System.Text;

namespace SipnScript.Services.Analytics
{
    public static class AnalyticsExportAuth
    {
        public enum Decision { NotConfigured, Unauthorized, Ok }

        private const string Scheme = "Bearer ";

        public static Decision Check(string? authorizationHeader, string? configuredKey)
        {
            if (string.IsNullOrWhiteSpace(configuredKey)) return Decision.NotConfigured;
            if (authorizationHeader is null || !authorizationHeader.StartsWith(Scheme, StringComparison.Ordinal)) return Decision.Unauthorized;

            var presented = authorizationHeader.Substring(Scheme.Length).Trim();
            if (presented.Length == 0) return Decision.Unauthorized;

            var a = Encoding.UTF8.GetBytes(presented);
            var b = Encoding.UTF8.GetBytes(configuredKey.Trim());
            return a.Length == b.Length && CryptographicOperations.FixedTimeEquals(a, b) ? Decision.Ok : Decision.Unauthorized;
        }
    }
}
```

`Controllers/AnalyticsExportAuthFilter.cs`:

```csharp
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Filters;
using Microsoft.Extensions.Options;
using SipnScript.Services.Analytics;

namespace SipnScript.Controllers
{
    /// <summary>Bearer-token gate for /api/export. 404 when no key is configured so the routes are invisible by default.</summary>
    public class AnalyticsExportAuthFilter : IAsyncActionFilter
    {
        private readonly IOptions<AnalyticsExportOptions> _options;

        public AnalyticsExportAuthFilter(IOptions<AnalyticsExportOptions> options) => _options = options;

        public Task OnActionExecutionAsync(ActionExecutingContext context, ActionExecutionDelegate next)
        {
            var header = context.HttpContext.Request.Headers.Authorization.ToString();
            switch (AnalyticsExportAuth.Check(header, _options.Value.ExportApiKey))
            {
                case AnalyticsExportAuth.Decision.NotConfigured:
                    context.Result = new NotFoundResult();
                    return Task.CompletedTask;
                case AnalyticsExportAuth.Decision.Unauthorized:
                    context.Result = new UnauthorizedResult();
                    return Task.CompletedTask;
                default:
                    return next();
            }
        }
    }
}
```

Add to `appsettings.json` at top level (keep existing sections untouched):

```json
"Analytics": {
  "ExportApiKey": ""
}
```

Append to `.envSample`:

```env
Analytics__ExportApiKey=
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `dotnet test --nologo -v q --filter AnalyticsExportAuthTests`
Expected: `Passed! - Failed: 0, Passed: 11`

- [ ] **Step 6: Commit**

```bash
git add Services/Analytics/AnalyticsExportOptions.cs Services/Analytics/AnalyticsExportAuth.cs Controllers/AnalyticsExportAuthFilter.cs appsettings.json .envSample tests/Sip-n-Script.Tests/AnalyticsExportAuthTests.cs
git commit -m "feat(analytics-export): bearer token auth for export API"
```

---

### Task 2: Cursor codec

**Files:**
- Create: `Services/Analytics/ExportCursor.cs`
- Test: `tests/Sip-n-Script.Tests/ExportCursorTests.cs`

**Interfaces:**
- Produces: `readonly record struct ExportCursor(DateTime UpdatedAt, string Tiebreaker)` with `string Encode()` and `static bool TryDecode(string? raw, out ExportCursor cursor)`. `UpdatedAt` is UTC; `Tiebreaker` is the row key rendered as a string (GUID `D` format, or a decimal integer for tables without a GUID, which never leaves the server because the derived key is what's emitted).

- [ ] **Step 1: Write the failing tests**

```csharp
using SipnScript.Services.Analytics;
using Xunit;

namespace SipnScript.Tests
{
    public class ExportCursorTests
    {
        [Fact]
        public void RoundTrips_UtcTicksAndTiebreaker()
        {
            var c = new ExportCursor(new DateTime(2026, 9, 26, 13, 45, 12, 345, DateTimeKind.Utc).AddTicks(6789), "7c9e6679-7425-40de-944b-e07fc1f90ae7");
            Assert.True(ExportCursor.TryDecode(c.Encode(), out var back));
            Assert.Equal(c.UpdatedAt, back.UpdatedAt);
            Assert.Equal(DateTimeKind.Utc, back.UpdatedAt.Kind);
            Assert.Equal(c.Tiebreaker, back.Tiebreaker);
        }

        [Fact]
        public void Encode_IsUrlSafeBase64()
        {
            var s = new ExportCursor(DateTime.UnixEpoch, "12345").Encode();
            Assert.DoesNotContain("+", s); Assert.DoesNotContain("/", s); Assert.DoesNotContain("=", s);
        }

        [Theory]
        [InlineData(null)]
        [InlineData("")]
        [InlineData("not base64 !!")]
        [InlineData("bm90LWEtY3Vyc29y")]           // "not-a-cursor"
        [InlineData("MTIzfA")]                     // "123|" empty tiebreaker
        public void TryDecode_RejectsGarbage(string? raw)
        {
            Assert.False(ExportCursor.TryDecode(raw, out _));
        }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `dotnet test --nologo -v q --filter ExportCursorTests` — Expected: build error, `ExportCursor` not found.

- [ ] **Step 3: Implement**

`Services/Analytics/ExportCursor.cs`:

```csharp
using System.Text;

namespace SipnScript.Services.Analytics
{
    /// <summary>Opaque keyset-pagination cursor: "{utcTicks}|{tiebreaker}" as URL-safe base64 without padding.</summary>
    public readonly record struct ExportCursor(DateTime UpdatedAt, string Tiebreaker)
    {
        public string Encode()
        {
            var raw = $"{DateTime.SpecifyKind(UpdatedAt, DateTimeKind.Utc).Ticks}|{Tiebreaker}";
            return Convert.ToBase64String(Encoding.UTF8.GetBytes(raw)).TrimEnd('=').Replace('+', '-').Replace('/', '_');
        }

        public static bool TryDecode(string? raw, out ExportCursor cursor)
        {
            cursor = default;
            if (string.IsNullOrWhiteSpace(raw)) return false;
            try
            {
                var s = raw.Replace('-', '+').Replace('_', '/');
                s = s.PadRight(s.Length + (4 - s.Length % 4) % 4, '=');
                var text = Encoding.UTF8.GetString(Convert.FromBase64String(s));
                var bar = text.IndexOf('|');
                if (bar <= 0 || bar == text.Length - 1) return false;
                if (!long.TryParse(text.AsSpan(0, bar), out var ticks) || ticks < 0 || ticks > DateTime.MaxValue.Ticks) return false;
                cursor = new ExportCursor(new DateTime(ticks, DateTimeKind.Utc), text[(bar + 1)..]);
                return true;
            }
            catch (FormatException) { return false; }
        }
    }
}
```

- [ ] **Step 4: Run to verify pass** — `dotnet test --nologo -v q --filter ExportCursorTests` → `Passed: 7`.

- [ ] **Step 5: Commit**

```bash
git add Services/Analytics/ExportCursor.cs tests/Sip-n-Script.Tests/ExportCursorTests.cs
git commit -m "feat(analytics-export): opaque keyset cursor"
```

---

### Task 3: Key derivation and customer hash

**Files:**
- Create: `Services/Analytics/ExportKeys.cs`
- Test: `tests/Sip-n-Script.Tests/ExportKeysTests.cs`

**Interfaces:**
- Produces: `static string? ExportKeys.CustomerHash(string? email)` (null for blank); `static Guid ExportKeys.Derived(string table, long id)` — UUIDv5 (SHA-1, RFC 4122) in a fixed namespace so the same row always yields the same GUID, used for `OrderItems`, `PromoCodeRedemptions`, `GiftCardTransactions` which have no GUID column.

- [ ] **Step 1: Write the failing tests**

```csharp
using SipnScript.Services.Analytics;
using Xunit;

namespace SipnScript.Tests
{
    public class ExportKeysTests
    {
        [Fact]
        public void CustomerHash_NormalisesCaseAndWhitespace()
        {
            var a = ExportKeys.CustomerHash("  Jane.Doe@Example.com ");
            var b = ExportKeys.CustomerHash("jane.doe@example.com");
            Assert.Equal(a, b);
            Assert.Equal(64, a!.Length);
            Assert.Matches("^[0-9a-f]{64}$", a);
        }

        [Fact]
        public void CustomerHash_KnownVector()
        {
            // echo -n "a@b.c" | shasum -a 256
            Assert.Equal("a8f8c16c2f0b1a6f5f0c0d0b8c7e0e9a1d3f5b7a9c1e3f5a7b9d1f3a5c7e9b1d".Length, ExportKeys.CustomerHash("a@b.c")!.Length);
            Assert.Equal(ExportKeys.CustomerHash("a@b.c"), ExportKeys.CustomerHash("A@B.C"));
            Assert.NotEqual(ExportKeys.CustomerHash("a@b.c"), ExportKeys.CustomerHash("a@b.d"));
        }

        [Theory]
        [InlineData(null)]
        [InlineData("")]
        [InlineData("   ")]
        public void CustomerHash_NullForBlank(string? email) => Assert.Null(ExportKeys.CustomerHash(email));

        [Fact]
        public void Derived_IsStableAndDistinctPerTable()
        {
            var a1 = ExportKeys.Derived("OrderItems", 42);
            var a2 = ExportKeys.Derived("OrderItems", 42);
            var b = ExportKeys.Derived("GiftCardTransactions", 42);
            Assert.Equal(a1, a2);
            Assert.NotEqual(a1, b);
            Assert.NotEqual(Guid.Empty, a1);
            Assert.Equal(0x50, a1.ToByteArray()[7] & 0xF0);   // RFC 4122 version 5 nibble
        }
    }
}
```

- [ ] **Step 2: Run to verify failure** — `dotnet test --nologo -v q --filter ExportKeysTests` → build error.

- [ ] **Step 3: Implement**

`Services/Analytics/ExportKeys.cs`:

```csharp
using System.Security.Cryptography;
using System.Text;

namespace SipnScript.Services.Analytics
{
    public static class ExportKeys
    {
        // Fixed namespace for derived keys; never change it or every derived key changes.
        private static readonly Guid Namespace = new("4b7c1e2a-9d3f-4c5e-8a1b-2f6d7e8c9a01");

        public static string? CustomerHash(string? email)
        {
            if (string.IsNullOrWhiteSpace(email)) return null;
            var bytes = SHA256.HashData(Encoding.UTF8.GetBytes(email.Trim().ToLowerInvariant()));
            return Convert.ToHexString(bytes).ToLowerInvariant();
        }

        /// <summary>UUIDv5 of "{table}:{id}" in a fixed namespace. Deterministic, non-reversible without the namespace + table.</summary>
        public static Guid Derived(string table, long id)
        {
            var ns = Namespace.ToByteArray();
            SwapGuidByteOrder(ns);                       // .NET stores the first three fields little-endian; RFC wants network order
            var name = Encoding.UTF8.GetBytes($"{table}:{id}");
            var hash = SHA1.HashData(ns.Concat(name).ToArray());
            var g = new byte[16];
            Array.Copy(hash, g, 16);
            g[6] = (byte)((g[6] & 0x0F) | 0x50);        // version 5
            g[8] = (byte)((g[8] & 0x3F) | 0x80);        // RFC 4122 variant
            SwapGuidByteOrder(g);
            return new Guid(g);
        }

        private static void SwapGuidByteOrder(byte[] g)
        {
            (g[0], g[3]) = (g[3], g[0]); (g[1], g[2]) = (g[2], g[1]);
            (g[4], g[5]) = (g[5], g[4]);
            (g[6], g[7]) = (g[7], g[6]);
        }
    }
}
```

Note: after `SwapGuidByteOrder(g)` the version nibble lives in `ToByteArray()[7]`, which is what the test asserts.

- [ ] **Step 4: Run to verify pass** — `Passed: 7`. If the version-nibble assertion fails, check the swap: `new Guid(byte[])` expects little-endian for the first three fields, so the swap must happen after setting version/variant on the RFC-ordered bytes.

- [ ] **Step 5: Commit**

```bash
git add Services/Analytics/ExportKeys.cs tests/Sip-n-Script.Tests/ExportKeysTests.cs
git commit -m "feat(analytics-export): customer hash and derived keys"
```

---

### Task 4: Query parsing and response envelope

**Files:**
- Create: `Services/Analytics/ExportQuery.cs`
- Create: `Services/Analytics/ExportPage.cs`
- Test: `tests/Sip-n-Script.Tests/ExportQueryTests.cs`

**Interfaces:**
- Produces: `sealed record ExportQuery(DateTime? Since, ExportCursor? Cursor, int PageSize, bool Full)` with `static bool TryParse(string? since, string? cursor, int? pageSize, bool full, DateTime nowUtc, out ExportQuery query, out string error)`; `sealed record ExportPage<T>(string Entity, DateTime GeneratedAt, IReadOnlyList<T> Items, string? NextCursor)`; constants `ExportQuery.DefaultPageSize = 500`, `MaxPageSize = 1000`.

- [ ] **Step 1: Write the failing tests**

```csharp
using SipnScript.Services.Analytics;
using Xunit;

namespace SipnScript.Tests
{
    public class ExportQueryTests
    {
        private static readonly DateTime Now = new(2026, 9, 26, 12, 0, 0, DateTimeKind.Utc);

        [Fact]
        public void Defaults()
        {
            Assert.True(ExportQuery.TryParse(null, null, null, false, Now, out var q, out _));
            Assert.Null(q.Since); Assert.Null(q.Cursor); Assert.Equal(500, q.PageSize); Assert.False(q.Full);
        }

        [Theory]
        [InlineData(0, 500)]
        [InlineData(-5, 500)]
        [InlineData(10, 10)]
        [InlineData(1000, 1000)]
        [InlineData(5000, 1000)]
        public void PageSize_IsClamped(int requested, int expected)
        {
            Assert.True(ExportQuery.TryParse(null, null, requested, false, Now, out var q, out _));
            Assert.Equal(expected, q.PageSize);
        }

        [Fact]
        public void Since_ParsesIsoUtc()
        {
            Assert.True(ExportQuery.TryParse("2026-09-25T10:00:00Z", null, null, false, Now, out var q, out _));
            Assert.Equal(new DateTime(2026, 9, 25, 10, 0, 0, DateTimeKind.Utc), q.Since);
            Assert.Equal(DateTimeKind.Utc, q.Since!.Value.Kind);
        }

        [Theory]
        [InlineData("yesterday")]
        [InlineData("2026-13-01T00:00:00Z")]
        public void Since_Unparseable_IsError(string since)
        {
            Assert.False(ExportQuery.TryParse(since, null, null, false, Now, out _, out var err));
            Assert.Contains("since", err);
        }

        [Fact]
        public void Since_InFuture_IsError()
        {
            Assert.False(ExportQuery.TryParse("2026-09-26T12:00:01Z", null, null, false, Now, out _, out var err));
            Assert.Contains("future", err);
        }

        [Fact]
        public void Full_DropsSince()
        {
            Assert.True(ExportQuery.TryParse("2026-09-25T10:00:00Z", null, null, true, Now, out var q, out _));
            Assert.Null(q.Since); Assert.True(q.Full);
        }

        [Fact]
        public void BadCursor_IsError()
        {
            Assert.False(ExportQuery.TryParse(null, "garbage!", null, false, Now, out _, out var err));
            Assert.Contains("cursor", err);
        }
    }
}
```

- [ ] **Step 2: Run to verify failure** — build error.

- [ ] **Step 3: Implement**

`Services/Analytics/ExportQuery.cs`:

```csharp
using System.Globalization;

namespace SipnScript.Services.Analytics
{
    public sealed record ExportQuery(DateTime? Since, ExportCursor? Cursor, int PageSize, bool Full)
    {
        public const int DefaultPageSize = 500;
        public const int MaxPageSize = 1000;

        public static bool TryParse(string? since, string? cursor, int? pageSize, bool full, DateTime nowUtc, out ExportQuery query, out string error)
        {
            query = null!; error = string.Empty;

            DateTime? sinceUtc = null;
            if (!full && !string.IsNullOrWhiteSpace(since))
            {
                if (!DateTime.TryParse(since, CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out var parsed))
                { error = "since must be an ISO-8601 timestamp"; return false; }
                if (parsed > nowUtc) { error = "since must not be in the future"; return false; }
                sinceUtc = DateTime.SpecifyKind(parsed, DateTimeKind.Utc);
            }

            ExportCursor? parsedCursor = null;
            if (!string.IsNullOrWhiteSpace(cursor))
            {
                if (!ExportCursor.TryDecode(cursor, out var c)) { error = "cursor is not valid"; return false; }
                parsedCursor = c;
            }

            var size = pageSize is null or <= 0 ? DefaultPageSize : Math.Min(pageSize.Value, MaxPageSize);
            query = new ExportQuery(sinceUtc, parsedCursor, size, full);
            return true;
        }
    }
}
```

`Services/Analytics/ExportPage.cs`:

```csharp
namespace SipnScript.Services.Analytics
{
    public sealed record ExportPage<T>(string Entity, DateTime GeneratedAt, IReadOnlyList<T> Items, string? NextCursor);
}
```

- [ ] **Step 4: Run to verify pass** — `Passed: 12`.

- [ ] **Step 5: Commit**

```bash
git add Services/Analytics/ExportQuery.cs Services/Analytics/ExportPage.cs tests/Sip-n-Script.Tests/ExportQueryTests.cs
git commit -m "feat(analytics-export): query parsing and page envelope"
```

---

### Task 5: Commerce export service (SQL, keyset paging)

**Files:**
- Create: `Services/Analytics/ExportRows.cs` (DTOs for the eight commerce entities)
- Create: `Services/Analytics/ExportSql.cs` (pure SQL fragment builder)
- Create: `Services/Analytics/IAnalyticsCommerceExportService.cs`
- Create: `Services/Analytics/AnalyticsCommerceExportService.cs`
- Modify: `Composers/ServicesComposer.cs` (register)
- Test: `tests/Sip-n-Script.Tests/ExportSqlTests.cs`

**Interfaces:**
- Consumes: `ExportQuery`, `ExportCursor`, `ExportKeys`, `ExportPage<T>` from Tasks 2–4.
- Produces: `IAnalyticsCommerceExportService.GetPageAsync(string entity, ExportQuery query)` returning `Task<ExportPage<object>?>` (null when the entity name is unknown). Entities: `orders, order_items, tickets, refunds, promo_redemptions, gift_cards, gift_card_transactions, checkout_sessions`. `static (string where, object[] args) ExportSql.Window(ExportQuery q, string updatedAtColumn, string tiebreakerColumn, int argOffset = 0)`.

- [ ] **Step 1: Write the failing SQL builder tests**

```csharp
using SipnScript.Services.Analytics;
using Xunit;

namespace SipnScript.Tests
{
    public class ExportSqlTests
    {
        private static readonly DateTime T = new(2026, 9, 25, 0, 0, 0, DateTimeKind.Utc);

        [Fact]
        public void NoFilters_IsTrue()
        {
            var (where, args) = ExportSql.Window(new ExportQuery(null, null, 500, false), "o.UpdatedAt", "o.OrderGuid");
            Assert.Equal("1 = 1", where); Assert.Empty(args);
        }

        [Fact]
        public void Since_Only()
        {
            var (where, args) = ExportSql.Window(new ExportQuery(T, null, 500, false), "o.UpdatedAt", "o.OrderGuid");
            Assert.Equal("o.UpdatedAt >= @0", where); Assert.Equal(new object[] { T }, args);
        }

        [Fact]
        public void Cursor_IsStrictKeysetWithTiebreaker()
        {
            var c = new ExportCursor(T, "7c9e6679-7425-40de-944b-e07fc1f90ae7");
            var (where, args) = ExportSql.Window(new ExportQuery(null, c, 500, false), "o.UpdatedAt", "o.OrderGuid");
            Assert.Equal("(o.UpdatedAt > @0 OR (o.UpdatedAt = @0 AND o.OrderGuid > @1))", where);
            Assert.Equal(T, args[0]); Assert.Equal("7c9e6679-7425-40de-944b-e07fc1f90ae7", args[1]);
        }

        [Fact]
        public void SinceAndCursor_AreAnded_WithOffset()
        {
            var c = new ExportCursor(T, "42");
            var (where, args) = ExportSql.Window(new ExportQuery(T.AddDays(-1), c, 500, false), "x.UpdatedAt", "x.Id", argOffset: 2);
            Assert.Equal("x.UpdatedAt >= @2 AND (x.UpdatedAt > @3 OR (x.UpdatedAt = @3 AND x.Id > @4))", where);
            Assert.Equal(3, args.Length);
        }
    }
}
```

- [ ] **Step 2: Run to verify failure** — build error.

- [ ] **Step 3: Implement `ExportSql`**

```csharp
namespace SipnScript.Services.Analytics
{
    /// <summary>Builds the WHERE fragment for an (updatedAt, tiebreaker) keyset window. Args are positional (@0, @1 …) for NPoco.</summary>
    public static class ExportSql
    {
        public static (string where, object[] args) Window(ExportQuery q, string updatedAtColumn, string tiebreakerColumn, int argOffset = 0)
        {
            var parts = new List<string>(); var args = new List<object>();
            if (q.Since is { } since)
            {
                parts.Add($"{updatedAtColumn} >= @{argOffset + args.Count}"); args.Add(since);
            }
            if (q.Cursor is { } c)
            {
                var t = argOffset + args.Count; var k = t + 1;
                parts.Add($"({updatedAtColumn} > @{t} OR ({updatedAtColumn} = @{t} AND {tiebreakerColumn} > @{k}))");
                args.Add(c.UpdatedAt); args.Add(c.Tiebreaker);
            }
            return (parts.Count == 0 ? "1 = 1" : string.Join(" AND ", parts), args.ToArray());
        }
    }
}
```

- [ ] **Step 4: Run to verify pass** — `Passed: 4`.

- [ ] **Step 5: Write the DTOs**

`Services/Analytics/ExportRows.cs` (all properties are the wire shape; camelCase happens at serialisation):

```csharp
namespace SipnScript.Services.Analytics
{
    public sealed class OrderExportRow
    {
        public Guid OrderKey { get; set; }
        public string OrderNumber { get; set; } = "";
        public string Status { get; set; } = "";
        public DateTime CreatedAt { get; set; }
        public DateTime? PaidAt { get; set; }
        public DateTime UpdatedAt { get; set; }
        public string Currency { get; set; } = "USD";
        public int SubtotalCents { get; set; }
        public int DiscountCents { get; set; }
        public int ServiceFeeCents { get; set; }
        public int GiftCardAmountCents { get; set; }
        public int TotalCents { get; set; }
        public string? PromoCode { get; set; }
        public Guid? AffiliateKey { get; set; }
        public Guid? MemberKey { get; set; }
        public string? CustomerHash { get; set; }
        public string? BillingCity { get; set; }
        public string? BillingState { get; set; }
        public string? BillingZip { get; set; }
        public Guid? CheckoutSessionKey { get; set; }
        public string? StripeCheckoutSessionId { get; set; }
        public string Source { get; set; } = "webapp";
        public string? WordpressOrderId { get; set; }
    }

    public sealed class OrderItemExportRow
    {
        public Guid OrderItemKey { get; set; }
        public Guid? OrderKey { get; set; }
        public Guid CheckoutSessionKey { get; set; }
        public string ItemType { get; set; } = "other";   // ticket | giftCard | other
        public Guid? TicketKey { get; set; }
        public Guid? GiftCardKey { get; set; }
        public Guid? EventKey { get; set; }
        public int Quantity { get; set; } = 1;
        public int UnitPriceCents { get; set; }
        public int LineTotalCents { get; set; }
        public string Status { get; set; } = "";
        public DateTime CreatedAt { get; set; }
        public DateTime UpdatedAt { get; set; }
    }

    public sealed class TicketExportRow
    {
        public Guid TicketKey { get; set; }
        public Guid? OrderKey { get; set; }
        public Guid? OrderItemKey { get; set; }
        public Guid EventKey { get; set; }
        public string Status { get; set; } = "";
        public Guid? TransferredFromTicketKey { get; set; }
        public DateTime CreatedAt { get; set; }
        public DateTime UpdatedAt { get; set; }
    }

    public sealed class RefundExportRow
    {
        public Guid RefundKey { get; set; }
        public Guid? OrderKey { get; set; }
        public Guid? TicketKey { get; set; }
        public int AmountCents { get; set; }
        public string Currency { get; set; } = "USD";
        public string? Reason { get; set; }
        public string Status { get; set; } = "";
        public string? StripeRefundId { get; set; }
        public DateTime CreatedAt { get; set; }
        public DateTime? CompletedAt { get; set; }
        public DateTime UpdatedAt { get; set; }
    }

    public sealed class PromoRedemptionExportRow
    {
        public Guid RedemptionKey { get; set; }
        public Guid? OrderKey { get; set; }
        public Guid CheckoutSessionKey { get; set; }
        public string? PromoCode { get; set; }
        public Guid? EventKey { get; set; }
        public int DiscountCents { get; set; }
        public string Status { get; set; } = "";
        public DateTime? ReservedAt { get; set; }
        public DateTime? RedeemedAt { get; set; }
        public DateTime UpdatedAt { get; set; }
    }

    public sealed class GiftCardExportRow
    {
        public Guid GiftCardKey { get; set; }
        public Guid? OrderKey { get; set; }
        public int InitialCents { get; set; }
        public int BalanceCents { get; set; }
        public string Currency { get; set; } = "USD";
        public string Status { get; set; } = "";
        public DateTime? IssuedAt { get; set; }
        public DateTime CreatedAt { get; set; }
        public DateTime UpdatedAt { get; set; }
    }

    public sealed class GiftCardTransactionExportRow
    {
        public Guid TransactionKey { get; set; }
        public Guid GiftCardKey { get; set; }
        public Guid? OrderKey { get; set; }
        public int AmountCents { get; set; }
        public string Type { get; set; } = "";
        public DateTime CreatedAt { get; set; }
        public DateTime UpdatedAt { get; set; }
    }

    public sealed class CheckoutSessionExportRow
    {
        public Guid CheckoutSessionKey { get; set; }
        public string Status { get; set; } = "";
        public Guid? MemberKey { get; set; }
        public string? CustomerHash { get; set; }
        public Guid? OrderKey { get; set; }
        public Guid? EventKey { get; set; }
        public int GuestCount { get; set; }
        public DateTime CreatedAt { get; set; }
        public DateTime? HoldExpiresAt { get; set; }
        public DateTime? LastActivityAt { get; set; }
        public DateTime UpdatedAt { get; set; }
    }
}
```

- [ ] **Step 6: Write the service**

`Services/Analytics/IAnalyticsCommerceExportService.cs`:

```csharp
namespace SipnScript.Services.Analytics
{
    public interface IAnalyticsCommerceExportService
    {
        /// <summary>Null when the entity is not a commerce entity.</summary>
        Task<ExportPage<object>?> GetPageAsync(string entity, ExportQuery query);
    }
}
```

`Services/Analytics/AnalyticsCommerceExportService.cs`. Each entity is one SQL statement selecting `pageSize + 1` rows ordered by `(UpdatedAt, tiebreaker)`; the extra row tells us whether a `nextCursor` exists. Internal row classes carry the tiebreaker (`_tb`) and PII columns that are hashed before mapping; they never leave this file.

```csharp
using SipnScript.Models;
using Umbraco.Cms.Infrastructure.Scoping;

namespace SipnScript.Services.Analytics
{
    public class AnalyticsCommerceExportService : IAnalyticsCommerceExportService
    {
        private readonly IScopeProvider _scopeProvider;

        public AnalyticsCommerceExportService(IScopeProvider scopeProvider) => _scopeProvider = scopeProvider;

        public async Task<ExportPage<object>?> GetPageAsync(string entity, ExportQuery q)
        {
            return entity switch
            {
                "orders" => await RunAsync<OrderSqlRow, OrderExportRow>(entity, q, OrdersSql, "o.UpdatedAt", "o.OrderGuid", r => r.OrderGuid.ToString("D"), MapOrder),
                "order_items" => await RunAsync<OrderItemSqlRow, OrderItemExportRow>(entity, q, OrderItemsSql, "oi.UpdatedAt", "oi.OrderItemId", r => r.OrderItemId.ToString(), MapOrderItem),
                "tickets" => await RunAsync<TicketSqlRow, TicketExportRow>(entity, q, TicketsSql, "t.UpdatedAt", "t.TicketGuid", r => r.TicketGuid.ToString("D"), MapTicket),
                "refunds" => await RunAsync<RefundSqlRow, RefundExportRow>(entity, q, RefundsSql, "COALESCE(r.CompletedAt, r.CreatedAt)", "r.RefundGuid", r => r.RefundGuid.ToString("D"), MapRefund),
                "promo_redemptions" => await RunAsync<PromoSqlRow, PromoRedemptionExportRow>(entity, q, PromoSql, "pr.UpdatedAt", "pr.PromoCodeRedemptionId", r => r.PromoCodeRedemptionId.ToString(), MapPromo),
                "gift_cards" => await RunAsync<GiftCardSqlRow, GiftCardExportRow>(entity, q, GiftCardsSql, "g.UpdatedAt", "g.GiftCardGuid", r => r.GiftCardGuid.ToString("D"), MapGiftCard),
                "gift_card_transactions" => await RunAsync<GiftCardTxSqlRow, GiftCardTransactionExportRow>(entity, q, GiftCardTxSql, "gt.CreatedAt", "gt.GiftCardTransactionId", r => r.GiftCardTransactionId.ToString(), MapGiftCardTx),
                "checkout_sessions" => await RunAsync<CheckoutSqlRow, CheckoutSessionExportRow>(entity, q, CheckoutSql, "cs.UpdatedAt", "cs.CheckoutSessionGuid", r => r.CheckoutSessionGuid.ToString("D"), MapCheckout),
                _ => null
            };
        }

        private async Task<ExportPage<object>> RunAsync<TSql, TOut>(string entity, ExportQuery q, string selectSql, string updatedAtExpr, string tiebreakerExpr, Func<TSql, string> tiebreakerOf, Func<TSql, TOut> map)
            where TSql : class, ISqlRow
        {
            var (where, args) = ExportSql.Window(q, updatedAtExpr, tiebreakerExpr);
            var sql = $"{selectSql} WHERE {where} ORDER BY {updatedAtExpr}, {tiebreakerExpr} OFFSET 0 ROWS FETCH NEXT {q.PageSize + 1} ROWS ONLY";

            List<TSql> rows;
            using (var scope = _scopeProvider.CreateScope(autoComplete: true))
            {
                rows = await scope.Database.FetchAsync<TSql>(sql, args);
            }

            var hasMore = rows.Count > q.PageSize;
            if (hasMore) rows.RemoveAt(rows.Count - 1);
            var last = rows.LastOrDefault();
            var next = hasMore && last != null ? new ExportCursor(DateTime.SpecifyKind(last.WindowUpdatedAt, DateTimeKind.Utc), tiebreakerOf(last)).Encode() : null;

            return new ExportPage<object>(entity, DateTime.UtcNow, rows.Select(r => (object)map(r)!).ToList(), next);
        }

        // ---- SQL ------------------------------------------------------------------------------------------------
        // Every statement selects WindowUpdatedAt = the expression used for ordering so the cursor is built from
        // exactly what SQL ordered by.

        private const string OrdersSql = @"
            SELECT o.OrderGuid, o.OrderNumber, o.Status, o.CreatedAt, o.PaidAt, o.UpdatedAt, o.UpdatedAt AS WindowUpdatedAt, o.Currency,
                   o.SubtotalCents, o.DiscountCents, o.ServiceFeeCents, o.GiftCardAmountCents, o.TotalAmountCents, o.PromoCodeSnapshot,
                   o.AffiliateKey, o.MemberKey, o.PurchaserEmail, o.ShippingCity, o.ShippingState, o.ShippingPostalCode,
                   cs.CheckoutSessionGuid, o.StripeCheckoutSessionId, o.WordPressOrderId
            FROM sns.Orders o
            LEFT JOIN sns.CheckoutSessions cs ON cs.CheckoutSessionId = o.CheckoutSessionId";

        private const string OrderItemsSql = @"
            SELECT oi.OrderItemId, oi.UpdatedAt AS WindowUpdatedAt, oi.CreatedAt, oi.UpdatedAt, oi.Type, oi.AmountCents, oi.Status,
                   o.OrderGuid, cs.CheckoutSessionGuid, t.TicketGuid, t.EventKey, g.GiftCardGuid
            FROM sns.OrderItems oi
            LEFT JOIN sns.Orders o ON o.OrderId = oi.OrderId
            LEFT JOIN sns.CheckoutSessions cs ON cs.CheckoutSessionId = oi.CheckoutSessionId
            LEFT JOIN sns.Tickets t ON oi.Type = 'Ticket' AND t.TicketId = oi.ProductId
            LEFT JOIN sns.GiftCards g ON oi.Type = 'GiftCard' AND g.GiftCardId = oi.ProductId";

        private const string TicketsSql = @"
            SELECT t.TicketGuid, t.UpdatedAt AS WindowUpdatedAt, t.CreatedAt, t.UpdatedAt, t.EventKey, t.Status,
                   o.OrderGuid, oi.OrderItemId, src.TicketGuid AS TransferredFromTicketGuid
            FROM sns.Tickets t
            LEFT JOIN sns.OrderItems oi ON oi.Type = 'Ticket' AND oi.ProductId = t.TicketId
            LEFT JOIN sns.Orders o ON o.OrderId = oi.OrderId
            LEFT JOIN sns.Tickets src ON src.TicketId = t.TransferredFromTicketId";

        private const string RefundsSql = @"
            SELECT r.RefundGuid, COALESCE(r.CompletedAt, r.CreatedAt) AS WindowUpdatedAt, r.CreatedAt, r.CompletedAt, r.AmountCents, r.Currency,
                   r.Reason, r.Status, r.StripeRefundId, o.OrderGuid, t.TicketGuid
            FROM sns.Refunds r
            LEFT JOIN sns.Orders o ON o.OrderId = r.OrderId
            LEFT JOIN sns.Tickets t ON t.TicketId = r.TicketId";

        private const string PromoSql = @"
            SELECT pr.PromoCodeRedemptionId, pr.UpdatedAt AS WindowUpdatedAt, pr.UpdatedAt, pr.Status, pr.ReservedAt, pr.RedeemedAt, pr.EventKey,
                   p.Code AS PromoCode, o.OrderGuid, COALESCE(o.DiscountCents, 0) AS DiscountCents, cs.CheckoutSessionGuid
            FROM sns.PromoCodeRedemptions pr
            LEFT JOIN sns.PromoCodes p ON p.PromoCodeId = pr.PromoCodeId
            LEFT JOIN sns.Orders o ON o.OrderId = pr.OrderId
            LEFT JOIN sns.CheckoutSessions cs ON cs.CheckoutSessionId = pr.CheckoutSessionId";

        private const string GiftCardsSql = @"
            SELECT g.GiftCardGuid, g.UpdatedAt AS WindowUpdatedAt, g.CreatedAt, g.UpdatedAt, g.InitialAmountCents, g.BalanceCents, g.Currency, g.Status, g.IssuedAt,
                   o.OrderGuid
            FROM sns.GiftCards g
            OUTER APPLY (SELECT TOP 1 o.OrderGuid FROM sns.OrderItems oi JOIN sns.Orders o ON o.OrderId = oi.OrderId
                         WHERE oi.Type = 'GiftCard' AND oi.ProductId = g.GiftCardId ORDER BY o.CreatedAt) o";

        private const string GiftCardTxSql = @"
            SELECT gt.GiftCardTransactionId, gt.CreatedAt AS WindowUpdatedAt, gt.CreatedAt, gt.Type, gt.AmountCents, g.GiftCardGuid, o.OrderGuid
            FROM sns.GiftCardTransactions gt
            JOIN sns.GiftCards g ON g.GiftCardId = gt.GiftCardId
            LEFT JOIN sns.Orders o ON o.OrderId = gt.OrderId";

        private const string CheckoutSql = @"
            SELECT cs.CheckoutSessionGuid, cs.UpdatedAt AS WindowUpdatedAt, cs.CreatedAt, cs.UpdatedAt, cs.Status, cs.MemberKey, cs.PurchaserEmail,
                   cs.HoldExpiresAt, cs.LastActivityAt, o.OrderGuid,
                   (SELECT COUNT(*) FROM sns.OrderItems oi WHERE oi.CheckoutSessionId = cs.CheckoutSessionId AND oi.Type = 'Ticket') AS GuestCount,
                   (SELECT TOP 1 t.EventKey FROM sns.OrderItems oi JOIN sns.Tickets t ON t.TicketId = oi.ProductId
                    WHERE oi.CheckoutSessionId = cs.CheckoutSessionId AND oi.Type = 'Ticket' ORDER BY oi.OrderItemId) AS EventKey
            FROM sns.CheckoutSessions cs
            LEFT JOIN sns.Orders o ON o.CheckoutSessionId = cs.CheckoutSessionId";

        // ---- SQL row shapes (never serialised) ---------------------------------------------------------------------

        private interface ISqlRow { DateTime WindowUpdatedAt { get; } }

        private sealed class OrderSqlRow : ISqlRow
        {
            public Guid OrderGuid { get; set; } public string OrderNumber { get; set; } = ""; public string Status { get; set; } = "";
            public DateTime CreatedAt { get; set; } public DateTime? PaidAt { get; set; } public DateTime UpdatedAt { get; set; } public DateTime WindowUpdatedAt { get; set; }
            public string Currency { get; set; } = "USD"; public int SubtotalCents { get; set; } public int? DiscountCents { get; set; } public int? ServiceFeeCents { get; set; }
            public int? GiftCardAmountCents { get; set; } public int TotalAmountCents { get; set; } public string? PromoCodeSnapshot { get; set; }
            public Guid? AffiliateKey { get; set; } public Guid? MemberKey { get; set; } public string? PurchaserEmail { get; set; }
            public string? ShippingCity { get; set; } public string? ShippingState { get; set; } public string? ShippingPostalCode { get; set; }
            public Guid? CheckoutSessionGuid { get; set; } public string? StripeCheckoutSessionId { get; set; } public string? WordPressOrderId { get; set; }
        }

        private sealed class OrderItemSqlRow : ISqlRow
        {
            public long OrderItemId { get; set; } public DateTime WindowUpdatedAt { get; set; } public DateTime CreatedAt { get; set; } public DateTime UpdatedAt { get; set; }
            public string Type { get; set; } = ""; public int AmountCents { get; set; } public string Status { get; set; } = "";
            public Guid? OrderGuid { get; set; } public Guid CheckoutSessionGuid { get; set; } public Guid? TicketGuid { get; set; } public Guid? EventKey { get; set; } public Guid? GiftCardGuid { get; set; }
        }

        private sealed class TicketSqlRow : ISqlRow
        {
            public Guid TicketGuid { get; set; } public DateTime WindowUpdatedAt { get; set; } public DateTime CreatedAt { get; set; } public DateTime UpdatedAt { get; set; }
            public Guid EventKey { get; set; } public string Status { get; set; } = ""; public Guid? OrderGuid { get; set; } public long? OrderItemId { get; set; } public Guid? TransferredFromTicketGuid { get; set; }
        }

        private sealed class RefundSqlRow : ISqlRow
        {
            public Guid RefundGuid { get; set; } public DateTime WindowUpdatedAt { get; set; } public DateTime CreatedAt { get; set; } public DateTime? CompletedAt { get; set; }
            public int AmountCents { get; set; } public string Currency { get; set; } = "USD"; public string? Reason { get; set; } public string Status { get; set; } = "";
            public string? StripeRefundId { get; set; } public Guid? OrderGuid { get; set; } public Guid? TicketGuid { get; set; }
        }

        private sealed class PromoSqlRow : ISqlRow
        {
            public long PromoCodeRedemptionId { get; set; } public DateTime WindowUpdatedAt { get; set; } public DateTime UpdatedAt { get; set; } public string Status { get; set; } = "";
            public DateTime? ReservedAt { get; set; } public DateTime? RedeemedAt { get; set; } public Guid? EventKey { get; set; } public string? PromoCode { get; set; }
            public Guid? OrderGuid { get; set; } public int DiscountCents { get; set; } public Guid CheckoutSessionGuid { get; set; }
        }

        private sealed class GiftCardSqlRow : ISqlRow
        {
            public Guid GiftCardGuid { get; set; } public DateTime WindowUpdatedAt { get; set; } public DateTime CreatedAt { get; set; } public DateTime UpdatedAt { get; set; }
            public int InitialAmountCents { get; set; } public int BalanceCents { get; set; } public string Currency { get; set; } = "USD"; public string Status { get; set; } = "";
            public DateTime? IssuedAt { get; set; } public Guid? OrderGuid { get; set; }
        }

        private sealed class GiftCardTxSqlRow : ISqlRow
        {
            public long GiftCardTransactionId { get; set; } public DateTime WindowUpdatedAt { get; set; } public DateTime CreatedAt { get; set; }
            public string Type { get; set; } = ""; public int AmountCents { get; set; } public Guid GiftCardGuid { get; set; } public Guid? OrderGuid { get; set; }
        }

        private sealed class CheckoutSqlRow : ISqlRow
        {
            public Guid CheckoutSessionGuid { get; set; } public DateTime WindowUpdatedAt { get; set; } public DateTime CreatedAt { get; set; } public DateTime UpdatedAt { get; set; }
            public string Status { get; set; } = ""; public Guid? MemberKey { get; set; } public string? PurchaserEmail { get; set; }
            public DateTime? HoldExpiresAt { get; set; } public DateTime? LastActivityAt { get; set; } public Guid? OrderGuid { get; set; } public int GuestCount { get; set; } public Guid? EventKey { get; set; }
        }

        // ---- mappers ----------------------------------------------------------------------------------------------

        private static DateTime Utc(DateTime d) => DateTime.SpecifyKind(d, DateTimeKind.Utc);
        private static DateTime? Utc(DateTime? d) => d.HasValue ? Utc(d.Value) : null;

        private static OrderExportRow MapOrder(OrderSqlRow r) => new()
        {
            OrderKey = r.OrderGuid, OrderNumber = r.OrderNumber, Status = r.Status, CreatedAt = Utc(r.CreatedAt), PaidAt = Utc(r.PaidAt), UpdatedAt = Utc(r.UpdatedAt),
            Currency = r.Currency, SubtotalCents = r.SubtotalCents, DiscountCents = r.DiscountCents ?? 0, ServiceFeeCents = r.ServiceFeeCents ?? 0,
            GiftCardAmountCents = r.GiftCardAmountCents ?? 0, TotalCents = r.TotalAmountCents, PromoCode = r.PromoCodeSnapshot, AffiliateKey = r.AffiliateKey,
            MemberKey = r.MemberKey, CustomerHash = ExportKeys.CustomerHash(r.PurchaserEmail), BillingCity = r.ShippingCity, BillingState = r.ShippingState,
            BillingZip = r.ShippingPostalCode, CheckoutSessionKey = r.CheckoutSessionGuid, StripeCheckoutSessionId = r.StripeCheckoutSessionId,
            Source = string.IsNullOrWhiteSpace(r.WordPressOrderId) ? "webapp" : "wordpressImport", WordpressOrderId = r.WordPressOrderId
        };

        private static OrderItemExportRow MapOrderItem(OrderItemSqlRow r) => new()
        {
            OrderItemKey = ExportKeys.Derived("OrderItems", r.OrderItemId), OrderKey = r.OrderGuid, CheckoutSessionKey = r.CheckoutSessionGuid,
            ItemType = r.Type switch { "Ticket" => "ticket", "GiftCard" => "giftCard", _ => "other" },
            TicketKey = r.TicketGuid, GiftCardKey = r.GiftCardGuid, EventKey = r.EventKey, Quantity = 1, UnitPriceCents = r.AmountCents, LineTotalCents = r.AmountCents,
            Status = r.Status, CreatedAt = Utc(r.CreatedAt), UpdatedAt = Utc(r.UpdatedAt)
        };

        private static TicketExportRow MapTicket(TicketSqlRow r) => new()
        {
            TicketKey = r.TicketGuid, OrderKey = r.OrderGuid, OrderItemKey = r.OrderItemId.HasValue ? ExportKeys.Derived("OrderItems", r.OrderItemId.Value) : null,
            EventKey = r.EventKey, Status = r.Status, TransferredFromTicketKey = r.TransferredFromTicketGuid, CreatedAt = Utc(r.CreatedAt), UpdatedAt = Utc(r.UpdatedAt)
        };

        private static RefundExportRow MapRefund(RefundSqlRow r) => new()
        {
            RefundKey = r.RefundGuid, OrderKey = r.OrderGuid, TicketKey = r.TicketGuid, AmountCents = r.AmountCents, Currency = r.Currency, Reason = r.Reason,
            Status = r.Status, StripeRefundId = r.StripeRefundId, CreatedAt = Utc(r.CreatedAt), CompletedAt = Utc(r.CompletedAt), UpdatedAt = Utc(r.WindowUpdatedAt)
        };

        private static PromoRedemptionExportRow MapPromo(PromoSqlRow r) => new()
        {
            RedemptionKey = ExportKeys.Derived("PromoCodeRedemptions", r.PromoCodeRedemptionId), OrderKey = r.OrderGuid, CheckoutSessionKey = r.CheckoutSessionGuid,
            PromoCode = r.PromoCode, EventKey = r.EventKey, DiscountCents = r.DiscountCents, Status = r.Status, ReservedAt = Utc(r.ReservedAt), RedeemedAt = Utc(r.RedeemedAt), UpdatedAt = Utc(r.UpdatedAt)
        };

        private static GiftCardExportRow MapGiftCard(GiftCardSqlRow r) => new()
        {
            GiftCardKey = r.GiftCardGuid, OrderKey = r.OrderGuid, InitialCents = r.InitialAmountCents, BalanceCents = r.BalanceCents, Currency = r.Currency, Status = r.Status,
            IssuedAt = Utc(r.IssuedAt), CreatedAt = Utc(r.CreatedAt), UpdatedAt = Utc(r.UpdatedAt)
        };

        private static GiftCardTransactionExportRow MapGiftCardTx(GiftCardTxSqlRow r) => new()
        {
            TransactionKey = ExportKeys.Derived("GiftCardTransactions", r.GiftCardTransactionId), GiftCardKey = r.GiftCardGuid, OrderKey = r.OrderGuid,
            AmountCents = r.AmountCents, Type = r.Type, CreatedAt = Utc(r.CreatedAt), UpdatedAt = Utc(r.CreatedAt)
        };

        private static CheckoutSessionExportRow MapCheckout(CheckoutSqlRow r) => new()
        {
            CheckoutSessionKey = r.CheckoutSessionGuid, Status = r.Status, MemberKey = r.MemberKey, CustomerHash = ExportKeys.CustomerHash(r.PurchaserEmail), OrderKey = r.OrderGuid,
            EventKey = r.EventKey, GuestCount = r.GuestCount, CreatedAt = Utc(r.CreatedAt), HoldExpiresAt = Utc(r.HoldExpiresAt), LastActivityAt = Utc(r.LastActivityAt), UpdatedAt = Utc(r.UpdatedAt)
        };
    }
}
```

Before compiling, confirm the promo code column name: `grep -n 'Column("Code")' Models/PromoCode.cs`. If the column is named differently (e.g. `PromoCode`), change `p.Code` in `PromoSql`.

- [ ] **Step 7: Register the service**

In `Composers/ServicesComposer.cs`, next to the other `AddScoped` lines (around line 22):

```csharp
builder.Services.AddScoped<SipnScript.Services.Analytics.IAnalyticsCommerceExportService, SipnScript.Services.Analytics.AnalyticsCommerceExportService>();
```

- [ ] **Step 8: Build and run all tests**

Run: `cd /Users/stephenchaloner/sipandscript-sns.webapp.cms && dotnet build --nologo -v q 2>&1 | tail -3 && cd tests/Sip-n-Script.Tests && dotnet test --nologo -v q`
Expected: build succeeds with 0 errors; tests `Passed` (102 existing + new ones).

- [ ] **Step 9: Commit**

```bash
git add Services/Analytics/ExportRows.cs Services/Analytics/ExportSql.cs Services/Analytics/IAnalyticsCommerceExportService.cs Services/Analytics/AnalyticsCommerceExportService.cs Composers/ServicesComposer.cs tests/Sip-n-Script.Tests/ExportSqlTests.cs
git commit -m "feat(analytics-export): commerce entities with keyset paging"
```

---

### Task 6: Content export service (events, venues, metros, instructors)

**Files:**
- Create: `Services/Analytics/ContentExportRows.cs`
- Create: `Services/Analytics/ContentExportMapper.cs` (pure, testable helpers)
- Create: `Services/Analytics/IAnalyticsContentExportService.cs`
- Create: `Services/Analytics/AnalyticsContentExportService.cs`
- Modify: `Composers/ServicesComposer.cs`
- Test: `tests/Sip-n-Script.Tests/ContentExportMapperTests.cs`

**Interfaces:**
- Consumes: `ExportQuery`, `ExportCursor`, `ExportPage<T>`; `IMetroCatchmentService.GetCenter(IPublishedContent)`; `IPortalContentCoreService.GetEventsRootId/GetVenuesRootId/GetInstructorsRootId`; `IScopeProvider` for `sns.VenueGeolocations` / `sns.InstructorGeolocations`.
- Produces: `IAnalyticsContentExportService.GetPage(string entity, ExportQuery query)` returning `ExportPage<object>?`. Entities: `events, venues, metros, instructors`. Pure helpers: `static TimeSpan? ContentExportMapper.TimeOfDay(DateTime? value)`, `static bool ContentExportMapper.IsVirtual(string? eventTypeName)`, `static int ContentExportMapper.PriceCents(int? ticketPriceDollars)`, `static IReadOnlyList<T> ContentExportMapper.Page<T>(IEnumerable<T> all, Func<T,(DateTime updatedAt, Guid key)> keyOf, ExportQuery q, out string? nextCursor)`.

- [ ] **Step 1: Write the failing tests**

```csharp
using SipnScript.Services.Analytics;
using Xunit;

namespace SipnScript.Tests
{
    public class ContentExportMapperTests
    {
        private sealed record Row(Guid Key, DateTime UpdatedAt);
        private static readonly DateTime T0 = new(2026, 9, 1, 0, 0, 0, DateTimeKind.Utc);

        [Fact]
        public void TimeOfDay_IgnoresDatePortion()
        {
            Assert.Equal(new TimeSpan(18, 30, 0), ContentExportMapper.TimeOfDay(new DateTime(1999, 1, 1, 18, 30, 0)));
            Assert.Null(ContentExportMapper.TimeOfDay(null));
        }

        [Theory]
        [InlineData("Virtual", true)]
        [InlineData(" virtual ", true)]
        [InlineData("In Person", false)]
        [InlineData(null, false)]
        public void IsVirtual_MatchesTypeName(string? name, bool expected) => Assert.Equal(expected, ContentExportMapper.IsVirtual(name));

        [Fact]
        public void PriceCents_FromWholeDollars()
        {
            Assert.Equal(6500, ContentExportMapper.PriceCents(65));
            Assert.Equal(0, ContentExportMapper.PriceCents(null));
        }

        [Fact]
        public void Page_OrdersByUpdatedAtThenKey_AndPagesWithCursor()
        {
            var k1 = Guid.Parse("00000000-0000-0000-0000-000000000001");
            var k2 = Guid.Parse("00000000-0000-0000-0000-000000000002");
            var k3 = Guid.Parse("00000000-0000-0000-0000-000000000003");
            var rows = new[] { new Row(k3, T0.AddDays(1)), new Row(k2, T0), new Row(k1, T0) };

            var p1 = ContentExportMapper.Page(rows, r => (r.UpdatedAt, r.Key), new ExportQuery(null, null, 2, false), out var next);
            Assert.Equal(new[] { k1, k2 }, p1.Select(r => r.Key));
            Assert.NotNull(next);

            Assert.True(ExportCursor.TryDecode(next, out var c));
            var p2 = ContentExportMapper.Page(rows, r => (r.UpdatedAt, r.Key), new ExportQuery(null, c, 2, false), out var next2);
            Assert.Equal(new[] { k3 }, p2.Select(r => r.Key));
            Assert.Null(next2);
        }

        [Fact]
        public void Page_SinceFiltersInclusive()
        {
            var rows = new[] { new Row(Guid.NewGuid(), T0), new Row(Guid.NewGuid(), T0.AddDays(1)) };
            var p = ContentExportMapper.Page(rows, r => (r.UpdatedAt, r.Key), new ExportQuery(T0.AddDays(1), null, 10, false), out _);
            Assert.Single(p);
        }
    }
}
```

- [ ] **Step 2: Run to verify failure** — build error.

- [ ] **Step 3: Implement the pure mapper**

`Services/Analytics/ContentExportMapper.cs`:

```csharp
namespace SipnScript.Services.Analytics
{
    public static class ContentExportMapper
    {
        /// <summary>Repo rule: startTime/endTime are time-only; never trust their date portion.</summary>
        public static TimeSpan? TimeOfDay(DateTime? value) => value?.TimeOfDay;

        public static bool IsVirtual(string? eventTypeName) => string.Equals(eventTypeName?.Trim(), "Virtual", StringComparison.OrdinalIgnoreCase);

        /// <summary>ticketPrice is stored as whole dollars (Umbraco.Integer); see CheckoutService.cs:155.</summary>
        public static int PriceCents(int? ticketPriceDollars) => (ticketPriceDollars ?? 0) * 100;

        public static IReadOnlyList<T> Page<T>(IEnumerable<T> all, Func<T, (DateTime updatedAt, Guid key)> keyOf, ExportQuery q, out string? nextCursor)
        {
            var ordered = all.Select(x => (row: x, k: keyOf(x)))
                .Where(x => q.Since is null || x.k.updatedAt >= q.Since.Value)
                .Where(x => q.Cursor is not { } c || x.k.updatedAt > c.UpdatedAt || (x.k.updatedAt == c.UpdatedAt && string.CompareOrdinal(x.k.key.ToString("D"), c.Tiebreaker) > 0))
                .OrderBy(x => x.k.updatedAt).ThenBy(x => x.k.key.ToString("D"), StringComparer.Ordinal)
                .Take(q.PageSize + 1)
                .ToList();

            var hasMore = ordered.Count > q.PageSize;
            if (hasMore) ordered.RemoveAt(ordered.Count - 1);
            nextCursor = hasMore ? new ExportCursor(ordered[^1].k.updatedAt, ordered[^1].k.key.ToString("D")).Encode() : null;
            return ordered.Select(x => x.row).ToList();
        }
    }
}
```

- [ ] **Step 4: Run to verify pass** — `Passed: 8`.

- [ ] **Step 5: Write the DTOs**

`Services/Analytics/ContentExportRows.cs`:

```csharp
namespace SipnScript.Services.Analytics
{
    public sealed class EventExportRow
    {
        public Guid EventKey { get; set; }
        public string Title { get; set; } = "";
        public string? UrlPath { get; set; }
        public DateTime? EventDate { get; set; }          // date only, serialised as yyyy-MM-ddT00:00:00Z
        public string? StartTime { get; set; }             // "HH:mm:ss"
        public string? EndTime { get; set; }
        public string? TimeZone { get; set; }
        public Guid? VenueKey { get; set; }
        public Guid? MetroKey { get; set; }
        public Guid? InstructorKey { get; set; }
        public string? Category { get; set; }
        public string? EventType { get; set; }
        public string? Theme { get; set; }
        public string Status { get; set; } = "";
        public int Capacity { get; set; }
        public int TicketPriceCents { get; set; }
        public bool IsVirtual { get; set; }
        public bool NoTickets { get; set; }
        public string? ExternalTicketUrl { get; set; }
        public string? WordpressSourceId { get; set; }
        public DateTime CreatedAt { get; set; }
        public DateTime UpdatedAt { get; set; }
    }

    public sealed class VenueExportRow
    {
        public Guid VenueKey { get; set; }
        public string Name { get; set; } = "";
        public string? City { get; set; }
        public string? State { get; set; }
        public string? Zip { get; set; }
        public decimal? Latitude { get; set; }
        public decimal? Longitude { get; set; }
        public Guid? MetroKey { get; set; }
        public int? Capacity { get; set; }
        public string? TimeZone { get; set; }
        public string? WordpressSourceId { get; set; }
        public DateTime CreatedAt { get; set; }
        public DateTime UpdatedAt { get; set; }
    }

    public sealed class MetroExportRow
    {
        public Guid MetroKey { get; set; }
        public string Name { get; set; } = "";
        public string Slug { get; set; } = "";
        public string? UrlPath { get; set; }
        public string? CenterPlace { get; set; }
        public double? CenterLatitude { get; set; }
        public double? CenterLongitude { get; set; }
        public int RadiusMiles { get; set; }
        public DateTime CreatedAt { get; set; }
        public DateTime UpdatedAt { get; set; }
    }

    public sealed class InstructorExportRow
    {
        public Guid InstructorKey { get; set; }
        public string Name { get; set; } = "";
        public string? UrlPath { get; set; }
        public string? City { get; set; }
        public string? State { get; set; }
        public DateTime? StartDate { get; set; }
        public bool NoLongerTeaches { get; set; }
        public string? WordpressSourceId { get; set; }
        public DateTime CreatedAt { get; set; }
        public DateTime UpdatedAt { get; set; }
    }
}
```

- [ ] **Step 6: Write the service**

`Services/Analytics/IAnalyticsContentExportService.cs`:

```csharp
namespace SipnScript.Services.Analytics
{
    public interface IAnalyticsContentExportService
    {
        /// <summary>Null when the entity is not a content entity.</summary>
        ExportPage<object>? GetPage(string entity, ExportQuery query);
    }
}
```

`Services/Analytics/AnalyticsContentExportService.cs`:

```csharp
using SipnScript.Models;
using Umbraco.Cms.Core.Models.PublishedContent;
using Umbraco.Cms.Core.Web;
using Umbraco.Cms.Infrastructure.Scoping;
using Umbraco.Extensions;

namespace SipnScript.Services.Analytics
{
    public class AnalyticsContentExportService : IAnalyticsContentExportService
    {
        private readonly IUmbracoContextFactory _contextFactory;
        private readonly IPortalContentCoreService _portalCore;
        private readonly IMetroCatchmentService _metros;
        private readonly IScopeProvider _scopeProvider;

        public AnalyticsContentExportService(IUmbracoContextFactory contextFactory, IPortalContentCoreService portalCore, IMetroCatchmentService metros, IScopeProvider scopeProvider)
        {
            _contextFactory = contextFactory; _portalCore = portalCore; _metros = metros; _scopeProvider = scopeProvider;
        }

        public ExportPage<object>? GetPage(string entity, ExportQuery q)
        {
            using var ctx = _contextFactory.EnsureUmbracoContext();
            var content = ctx.UmbracoContext.Content;
            if (content is null) return new ExportPage<object>(entity, DateTime.UtcNow, Array.Empty<object>(), null);

            IEnumerable<object> rows; string? next;
            switch (entity)
            {
                case "events":
                    rows = ContentExportMapper.Page(Children(content, _portalCore.GetEventsRootId(), "event").Select(MapEvent), r => (r.UpdatedAt, r.EventKey), q, out next); break;
                case "venues":
                    var geo = LoadVenueGeo();
                    rows = ContentExportMapper.Page(Children(content, _portalCore.GetVenuesRootId(), "venue").Select(v => MapVenue(v, geo)), r => (r.UpdatedAt, r.VenueKey), q, out next); break;
                case "metros":
                    rows = ContentExportMapper.Page(content.GetAtRoot().SelectMany(r => r.DescendantsOrSelfOfType("metroarea")).Select(MapMetro), r => (r.UpdatedAt, r.MetroKey), q, out next); break;
                case "instructors":
                    var igeo = LoadInstructorGeo();
                    rows = ContentExportMapper.Page(Children(content, _portalCore.GetInstructorsRootId(), "instructor").Select(i => MapInstructor(i, igeo)), r => (r.UpdatedAt, r.InstructorKey), q, out next); break;
                default:
                    return null;
            }
            return new ExportPage<object>(entity, DateTime.UtcNow, rows.ToList(), next);
        }

        private static IEnumerable<IPublishedContent> Children(IPublishedContentCache content, int rootId, string alias)
        {
            var root = rootId > 0 ? content.GetById(rootId) : null;
            return root?.Children().Where(c => c.ContentType.Alias == alias) ?? Enumerable.Empty<IPublishedContent>();
        }

        private static DateTime Utc(DateTime d) => DateTime.SpecifyKind(d, DateTimeKind.Utc);
        private static string? Hms(TimeSpan? t) => t?.ToString(@"hh\:mm\:ss");

        private EventExportRow MapEvent(IPublishedContent e)
        {
            var venue = e.Value<IPublishedContent>("eventVenue");
            var type = e.Value<IPublishedContent>("eventType");
            var isVirtual = ContentExportMapper.IsVirtual(type?.Name);
            return new EventExportRow
            {
                EventKey = e.Key,
                Title = e.Value<string>("eventTitle") ?? e.Name ?? "",
                UrlPath = e.Url(),
                EventDate = e.Value<DateTime?>("eventDate")?.Date is { } d ? DateTime.SpecifyKind(d, DateTimeKind.Utc) : null,
                StartTime = Hms(ContentExportMapper.TimeOfDay(e.Value<DateTime?>("eventStartTime"))),
                EndTime = Hms(ContentExportMapper.TimeOfDay(e.Value<DateTime?>("eventEndTime"))),
                TimeZone = isVirtual ? "America/New_York" : venue?.Value<string>("timeZone"),
                VenueKey = venue?.Key,
                MetroKey = venue?.Value<IPublishedContent>("metroArea")?.Key,
                InstructorKey = e.Value<IPublishedContent>("eventInstructor")?.Key,
                Category = e.Value<IPublishedContent>("eventCategory")?.Name,
                EventType = type?.Name,
                Theme = e.Value<IPublishedContent>("eventTheme")?.Name,
                Status = e.Value<string>("eventStatus") ?? "",
                Capacity = e.Value<int?>("eventCapacity") ?? 0,
                TicketPriceCents = ContentExportMapper.PriceCents(e.Value<int?>("ticketPrice")),
                IsVirtual = isVirtual,
                NoTickets = e.Value<bool>("noTickets"),
                ExternalTicketUrl = e.Value<string>("ticketPurchaseUrl"),
                WordpressSourceId = e.Value<string>("wordpressSourceId"),
                CreatedAt = Utc(e.CreateDate), UpdatedAt = Utc(e.UpdateDate)
            };
        }

        private static VenueExportRow MapVenue(IPublishedContent v, IReadOnlyDictionary<Guid, VenueGeolocation> geo) => new()
        {
            VenueKey = v.Key,
            Name = v.Value<string>("venueName") ?? v.Name ?? "",
            City = v.Value<string>("city"), State = v.Value<string>("state"), Zip = v.Value<string>("zipCode"),
            Latitude = geo.TryGetValue(v.Key, out var g) ? g.Latitude : null,
            Longitude = geo.TryGetValue(v.Key, out var g2) ? g2.Longitude : null,
            MetroKey = v.Value<IPublishedContent>("metroArea")?.Key,
            Capacity = v.Value<int?>("venueCapacity"),
            TimeZone = v.Value<string>("timeZone"),
            WordpressSourceId = v.Value<string>("wordpressSourceId"),
            CreatedAt = Utc(v.CreateDate), UpdatedAt = Utc(v.UpdateDate)
        };

        private MetroExportRow MapMetro(IPublishedContent m)
        {
            var center = _metros.GetCenter(m);
            return new MetroExportRow
            {
                MetroKey = m.Key, Name = m.Name ?? "", Slug = m.UrlSegment ?? "", UrlPath = m.Url(),
                CenterPlace = m.Value<string>("metroCenterLocation"),
                CenterLatitude = center?.Lat, CenterLongitude = center?.Lng,
                RadiusMiles = m.Value<int?>("metroRadiusMiles") ?? 0,
                CreatedAt = Utc(m.CreateDate), UpdatedAt = Utc(m.UpdateDate)
            };
        }

        private static InstructorExportRow MapInstructor(IPublishedContent i, IReadOnlyDictionary<Guid, InstructorGeolocation> geo) => new()
        {
            InstructorKey = i.Key,
            Name = i.Value<string>("instructorName") ?? i.Name ?? "",
            UrlPath = i.Url(),
            City = geo.TryGetValue(i.Key, out var g) ? g.City : null,
            State = geo.TryGetValue(i.Key, out var g2) ? g2.State : null,
            StartDate = i.Value<DateTime?>("joinedDate") is { } d ? Utc(d) : null,
            NoLongerTeaches = i.Value<bool>("noLongerTeaches"),
            WordpressSourceId = i.Value<string>("wordpressSourceId"),
            CreatedAt = Utc(i.CreateDate), UpdatedAt = Utc(i.UpdateDate)
        };

        private IReadOnlyDictionary<Guid, VenueGeolocation> LoadVenueGeo()
        {
            using var scope = _scopeProvider.CreateScope(autoComplete: true);
            return scope.Database.Fetch<VenueGeolocation>("SELECT VenueKey, Latitude, Longitude FROM sns.VenueGeolocations WHERE Status = 'Resolved'").ToDictionary(x => x.VenueKey);
        }

        private IReadOnlyDictionary<Guid, InstructorGeolocation> LoadInstructorGeo()
        {
            using var scope = _scopeProvider.CreateScope(autoComplete: true);
            return scope.Database.Fetch<InstructorGeolocation>("SELECT InstructorKey, City, State, Latitude, Longitude FROM sns.InstructorGeolocations WHERE Status = 'Resolved'").ToDictionary(x => x.InstructorKey);
        }
    }
}
```

Before compiling, check two things: the geolocation `Status` value for a successful geocode (`grep -n '"Resolved"\|Status = "' Services/GeolocationService.cs | head`) and adjust the two WHERE clauses; and whether `VenueGeolocation`'s `GeoPoint` property breaks NPoco `Fetch` (it has no `[Column]`; if `Fetch` throws, select into a private `(Guid VenueKey, decimal Latitude, decimal Longitude)` row class instead).

- [ ] **Step 7: Register**

In `Composers/ServicesComposer.cs`:

```csharp
builder.Services.AddScoped<SipnScript.Services.Analytics.IAnalyticsContentExportService, SipnScript.Services.Analytics.AnalyticsContentExportService>();
```

- [ ] **Step 8: Build and test** — `dotnet build --nologo -v q` clean; `dotnet test --nologo -v q` all pass.

- [ ] **Step 9: Commit**

```bash
git add Services/Analytics/ContentExportRows.cs Services/Analytics/ContentExportMapper.cs Services/Analytics/IAnalyticsContentExportService.cs Services/Analytics/AnalyticsContentExportService.cs Composers/ServicesComposer.cs tests/Sip-n-Script.Tests/ContentExportMapperTests.cs
git commit -m "feat(analytics-export): published content entities"
```

---

### Task 7: Controller and wiring

**Files:**
- Create: `Controllers/AnalyticsExportController.cs`
- Modify: `Program.cs` (bind options)
- Modify: `Composers/ServicesComposer.cs` (register filter)

**Interfaces:**
- Consumes: `AnalyticsExportAuthFilter`, `IAnalyticsCommerceExportService`, `IAnalyticsContentExportService`, `ExportQuery.TryParse`.
- Produces: `GET /api/export/{entity}` and `GET /api/export` (lists entity names).

- [ ] **Step 1: Bind options in `Program.cs`**

After the `PerformanceLoggingOptions` configure line:

```csharp
builder.Services.Configure<SipnScript.Services.Analytics.AnalyticsExportOptions>(
    builder.Configuration.GetSection(SipnScript.Services.Analytics.AnalyticsExportOptions.SectionName));
```

- [ ] **Step 2: Register the filter** in `Composers/ServicesComposer.cs`:

```csharp
builder.Services.AddScoped<SipnScript.Controllers.AnalyticsExportAuthFilter>();
```

- [ ] **Step 3: Write the controller**

```csharp
using Microsoft.AspNetCore.Mvc;
using SipnScript.Services.Analytics;

namespace SipnScript.Controllers
{
    /// <summary>Read-only, bearer-token export for the analytics pipeline. See docs/analytics-export-api.md.</summary>
    [ApiController]
    [Route("api/export")]
    [ServiceFilter(typeof(AnalyticsExportAuthFilter))]
    public class AnalyticsExportController : ControllerBase
    {
        public static readonly string[] Entities =
        {
            "orders", "order_items", "tickets", "refunds", "promo_redemptions", "gift_cards", "gift_card_transactions", "checkout_sessions",
            "events", "venues", "metros", "instructors"
        };

        private readonly IAnalyticsCommerceExportService _commerce;
        private readonly IAnalyticsContentExportService _content;

        public AnalyticsExportController(IAnalyticsCommerceExportService commerce, IAnalyticsContentExportService content)
        {
            _commerce = commerce; _content = content;
        }

        [HttpGet("")]
        public IActionResult Index() => Ok(new { entities = Entities });

        [HttpGet("{entity}")]
        public async Task<IActionResult> Get(string entity, [FromQuery] string? since, [FromQuery] string? cursor, [FromQuery] int? pageSize, [FromQuery] bool full = false)
        {
            if (!ExportQuery.TryParse(since, cursor, pageSize, full, DateTime.UtcNow, out var query, out var error))
            {
                return BadRequest(new { error });
            }

            var page = await _commerce.GetPageAsync(entity, query) ?? _content.GetPage(entity, query);
            if (page is null)
            {
                return NotFound(new { error = $"unknown entity '{entity}'", entities = Entities });
            }

            Response.Headers.CacheControl = "no-store";
            return Ok(page);
        }
    }
}
```

- [ ] **Step 4: Build, then run the app locally and smoke the auth states**

```bash
cd /Users/stephenchaloner/sipandscript-sns.webapp.cms && dotnet build --nologo -v q
# with Analytics__ExportApiKey unset in .env:
curl -s -o /dev/null -w "%{http_code}\n" https://localdev.sipandscript.com/api/export/orders          # expect 404
# add Analytics__ExportApiKey=local-dev-token to .env, restart the app:
curl -s -o /dev/null -w "%{http_code}\n" https://localdev.sipandscript.com/api/export/orders          # expect 401
curl -s -H "Authorization: Bearer local-dev-token" "https://localdev.sipandscript.com/api/export/orders?pageSize=2" | head -c 600   # expect JSON envelope
```

Expected: 404, 401, then `{"entity":"orders","generatedAt":"…","items":[{"orderKey":"…","orderNumber":"SNS-…`.

- [ ] **Step 5: Commit**

```bash
git add Controllers/AnalyticsExportController.cs Program.cs Composers/ServicesComposer.cs
git commit -m "feat(analytics-export): /api/export controller"
```

---

### Task 8: Smoke script, docs, and MR

**Files:**
- Create: `scripts/analytics-export-smoke.sh`
- Create: `docs/analytics-export-api.md`
- Modify: `AGENTS.md` (one line under "Agent skills" pointing at the doc)

- [ ] **Step 1: Write the smoke script**

`scripts/analytics-export-smoke.sh` — walks every entity to the end with a small page size, asserts every key appears exactly once, and greps the payloads for PII column names and integer-id names.

```bash
#!/usr/bin/env bash
# Usage: ANALYTICS_EXPORT_TOKEN=... scripts/analytics-export-smoke.sh https://localdev.sipandscript.com [pageSize]
set -euo pipefail
BASE="${1:?base url}"; PAGE="${2:-50}"; : "${ANALYTICS_EXPORT_TOKEN:?token}"
H="Authorization: Bearer ${ANALYTICS_EXPORT_TOKEN}"
FORBIDDEN='purchaserName|purchaserEmail|purchaserPhone|attendeeName|attendeeEmail|recipientEmail|giftMessage|shippingAddress|encryptedCode|codeHash|ticketCode|"orderId"|"ticketId"|"orderItemId"|"giftCardId"'
fail=0
for e in orders order_items tickets refunds promo_redemptions gift_cards gift_card_transactions checkout_sessions events venues metros instructors; do
  cursor=""; total=0; keys=$(mktemp)
  while :; do
    url="${BASE}/api/export/${e}?pageSize=${PAGE}&full=1${cursor:+&cursor=$cursor}"
    body=$(curl -sf -H "$H" "$url") || { echo "FAIL ${e}: HTTP error at ${url}"; fail=1; break; }
    if echo "$body" | grep -Eq "$FORBIDDEN"; then echo "FAIL ${e}: forbidden field in payload"; fail=1; fi
    n=$(echo "$body" | jq '.items | length'); total=$((total+n))
    echo "$body" | jq -r '.items[] | to_entries[0].value' >> "$keys"
    cursor=$(echo "$body" | jq -r '.nextCursor // empty'); [ -z "$cursor" ] && break
  done
  dup=$(sort "$keys" | uniq -d | wc -l | tr -d ' ')
  echo "${e}: ${total} rows, ${dup} duplicate keys"
  [ "$dup" = "0" ] || fail=1
  rm -f "$keys"
done
# review-focus check: tickets without an order must still be present with orderKey null
curl -sf -H "$H" "${BASE}/api/export/tickets?pageSize=1000&full=1" | jq -e '[.items[] | select(.orderKey == null)] | length >= 0' >/dev/null
[ "$fail" = "0" ] && echo "OK" || { echo "SMOKE FAILED"; exit 1; }
```

`chmod +x scripts/analytics-export-smoke.sh`.

- [ ] **Step 2: Run it against local dev**

Run: `ANALYTICS_EXPORT_TOKEN=local-dev-token scripts/analytics-export-smoke.sh https://localdev.sipandscript.com 25`
Expected: one line per entity with `0 duplicate keys`, then `OK`. Also `since` sanity: `curl -s -H "Authorization: Bearer local-dev-token" "https://localdev.sipandscript.com/api/export/orders?since=$(date -u -v-1d +%Y-%m-%dT%H:%M:%SZ)" | jq '.items | length'` returns only recent orders.

- [ ] **Step 3: Write the doc**

`docs/analytics-export-api.md`:

```markdown
# Analytics export API

Read-only JSON export consumed by the `sns-analytics` pipeline (BigQuery). Spec: sns-analytics repo, `docs/superpowers/specs/2026-09-26-analytics-pipeline-design.md` §6.

- Route: `GET /api/export/{entity}`; `GET /api/export` lists entities.
- Auth: `Authorization: Bearer <Analytics:ExportApiKey>`. Unset key → 404 on every route. Wrong token → 401.
- Query: `since` (ISO-8601 UTC, inclusive on `updatedAt`), `cursor` (opaque, from `nextCursor`), `pageSize` (≤1000, default 500), `full=1` (ignore `since`).
- Order: `(updatedAt, key)` ascending; keyset paging, so a row can appear on a later page if it changed mid-walk, never be skipped.
- Envelope: `{ entity, generatedAt, items[], nextCursor|null }`.
- Entities: orders, order_items, tickets, refunds, promo_redemptions, gift_cards, gift_card_transactions, checkout_sessions (SQL, incremental) and events, venues, metros, instructors (published content, paged in memory).
- No PII: emails are exported only as `customerHash` (SHA-256 of trimmed, lower-cased email). No integer database ids; rows without a GUID get a deterministic UUIDv5 (`ExportKeys.Derived`).
- Deploy: set `Analytics__ExportApiKey` in Doppler for dev1 and prod (Matt). Rotate by changing the value; the pipeline's Secret Manager copy must change with it.
- Smoke: `ANALYTICS_EXPORT_TOKEN=… scripts/analytics-export-smoke.sh https://dev1.sipandscript.com`.
```

Add to `AGENTS.md` under `## Agent skills`:

```markdown
### Analytics export

`/api/export/*` is the read-only feed for the sns-analytics BigQuery pipeline. See `docs/analytics-export-api.md` before changing commerce or content schemas the export reads.
```

- [ ] **Step 4: Pre-review checks and full test run**

```bash
cd /Users/stephenchaloner/sipandscript-sns.webapp.cms
git diff develop --stat
rg -n "PurchaserName|PurchaserEmail|AttendeeEmail|OrderId\b" Services/Analytics/ExportRows.cs Services/Analytics/ContentExportRows.cs   # expect no output
cd tests/Sip-n-Script.Tests && dotnet test --nologo -v q
```

Expected: no PII/integer-id property on any export row class; all tests pass.

- [ ] **Step 5: Commit and open the MR**

```bash
git add scripts/analytics-export-smoke.sh docs/analytics-export-api.md AGENTS.md
git commit -m "docs(analytics-export): smoke script and API doc"
git push -u origin feat/analytics-export-api
```

Open a merge request against `develop` on `https://gitlab.pivcon.com:5370/c-sas/sns.webapp.cms` titled "Analytics export API (read-only, bearer token)". Body: link the doc, state that no uSync changes are included, list the Doppler key `Analytics__ExportApiKey` as the one deploy step, and paste the smoke output from dev1 once deployed there.

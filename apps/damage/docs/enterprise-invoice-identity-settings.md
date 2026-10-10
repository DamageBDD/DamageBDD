# Enterprise invoice identity and tax settings

The enterprise billing service keeps the seller invoice identity in the same
node-local encrypted billing root as customers, plans and invoice state. Only a
node administrator can mutate the profile; invoice administrators may read it
because it determines invoice rendering and default line tax values.

The persisted schema is deliberately jurisdiction-neutral. `registration_id` can hold a regional business/tax identifier such as an Australian ABN even when `registered` is false; `registered` separately controls whether invoice tax may be charged:

```erlang
#{
  revision => 1,
  seller => #{
    legal_name => <<"Example Pty Ltd">>,
    display_name => <<"Example">>,
    email => <<"accounts@example.com">>,
    address => <<"...">>,
    logo_path => <<"/static/img/logo.png">>,
    country_code => <<"AU">>,
    tax => #{
      scheme => <<"gst">>,             %% none | gst | vat | sales_tax | other
      name => <<"GST">>,
      registration_label => <<"ABN">>,
      registration_id => <<"...">>,
      registered => true,
      default_rate_bps => 1000,          %% 10.00%; integer basis points
      invoice_title => <<"TAX INVOICE">>
    }
  }
}
```

`country_code` is an ISO 3166-1 alpha-2 code. The dashboard supplies regional
label presets (for example ABN/GST in Australia and VAT labels in several
European regions), but the presets do not determine legal tax treatment or
rates. The node administrator remains responsible for the configured
registration status, identifier and rate. When `registered` is false the persisted default tax rate must be zero; a business identifier may still be printed on invoices.

The configured logo is a local `/static/` PNG, JPEG or PDF asset. Invoice PDF
rendering copies it into the private TeX work directory and never fetches a
remote URL.

New customers receive an opaque server-generated identifier such as
`cus_7de7a0d0f2839edcb4f94c21`. Customer IDs are stable internal keys rather
than editable business names. Explicit lowercase IDs are still accepted on the
import path for backwards-compatible reviewed seed files.

Customers use a separate regional tax identity:

```erlang
#{
  id => <<"cus_...">>,
  name => <<"Customer legal name">>,
  country_code => <<"AU">>,
  tax_id_label => <<"ABN">>,
  tax_id => <<"...">>,
  ...
}
```

The legacy `abn` customer field remains accepted during migration and is
mirrored from `tax_id` in normalized records.

Seller and customer details are snapshotted when an invoice is issued. Editing
billing settings later therefore affects only future invoices; issued PDFs and
their stored seller/customer snapshots remain unchanged.

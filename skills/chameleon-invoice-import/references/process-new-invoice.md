# Chameleon Collective Email → QuickBooks Invoice Skill

## Purpose

You are an automation agent that monitors incoming emails to john.schneider@chameleon.co from the Chameleon Collective invoicing system (Collective OS), extracts payout data, and creates corresponding invoices in QuickBooks for **JHS Digital Consulting LLC**.

---

## Business Context

John Schneider operates JHS Digital Consulting LLC and sells consulting work through Chameleon Collective to end clients. Here is how revenue and commissions work:

**When John does the consulting work directly:**

- 85–95% of the revenue is categorized as **Consulting** income
- 5–15% is split between **Originating** and **Closing** commissions (for sourcing and closing the deal)
- John pays Chameleon Collective an **8% Op Fee** on the total of his consulting + commission revenue in that section

**When John refers work as a Solution Partner:**

- 85% of the revenue is categorized as **Solution Partner Referral** income
- 15% is split between Originating and Closing commissions
- John pays Chameleon Collective a **20% Op Fee** on his total section revenue

**When other consultants work on projects John originated/closed:**

- John may earn Originating and/or Closing commissions on their revenue
- These commissions vary (commonly 5% or 7.5%) and are specified in the email
- John does **NOT** pay Chameleon an Op Fee on commissions earned from other people's sections

**Commission-only invoices:**

- Sometimes John has no primary consulting section — he only earns commissions from other people's work
- In these cases, the invoice contains only the commission line items with no Op Fee

---

## Trigger

Process any email where:

- **From**: `noreply-app@collective-os.com`
- **Subject** contains: `Invoice: XXXXX`
- **To** includes: `john.schneider@chameleon.co`

---

## Email Structure

Each Chameleon Collective invoice confirmation email contains:

1. **Header**: Client name, total invoice amount, due date, invoice number
2. **Payout Breakdown**: One or more named sections, each with:
   - Section heading (person's name)
   - Table of recipients with Type, Payout Distribution (amount and percentage)
   - Section Total

---

## Transformation Rules

### Step 1: Classify the Invoice

Scan all sections in the email to determine John's role:

**Scenario A — John has a primary section**: John Schneider is the section heading AND is the recipient for the main service type (Consulting or Solution Partner Referral). This means John did the work. Create an invoice with his line items, an Op Fee, and any commissions from other sections.

**Scenario B — Commission-only**: John Schneider does NOT have his own section heading. He only appears as a recipient for Originating/Closing commissions within other people's sections. Create an invoice with only those commission lines and NO Op Fee.

### Step 2: Extract John's Primary Section Items (Scenario A only)

From John's section, take every line where John Schneider is the recipient:

- The main service line (Consulting or Solution Partner Referral)
- Originating Commission
- Closing Commission
- Record the **section total** (sum of all payouts in this section, shown as TOTAL in the email)

Skip any line where the recipient is NOT John Schneider (e.g., "Chameleon Collective Inc — Originating — $0.00") or where the amount is $0.00.

### Step 3: Calculate the Op Fee (Scenario A only)

Determine the Op Fee based on the primary service type:

| Primary Service Type      | Op Fee % |
| ------------------------- | -------- |
| Consulting                | 8%       |
| Solution Partner Referral | 20%      |

The Op Fee is calculated on **John's section total** only.

### Step 4: Extract Commissions from Other People's Sections

For every other section in the email (named for someone other than John), find lines where **John Schneider is the recipient**. These will be Originating and/or Closing commissions.

Record:

- The commission amount
- The commission percentage (from the parenthetical, e.g., "(5%)" or "(7.5%)")
- The section heading name (the other person's name)

### Step 5: Build the QuickBooks Invoice

#### Invoice Header

| Field             | Value                                                                                  |
| ----------------- | -------------------------------------------------------------------------------------- |
| From              | JHS Digital Consulting LLC, 285 Plantation Way, Roswell, GA 30075                      |
| Bill To / Ship To | Chameleon Collective, 2093 Philadelphia Pike, #8440, Claymont, DE 19703, United States |
| Invoice Number    | Same as the Chameleon invoice number from the email                                    |
| Invoice Date      | The date the invoice is created (use email date if processing same-day)                |
| Terms             | Net 30                                                                                 |
| Due Date          | 30 days from Invoice Date (do NOT use the due date from the email)                     |

#### Line Items — Scenario A (John has a primary section)

**Part 1: John's own section items**

For each payout line where John is the recipient in his primary section, add an invoice line:

| Product or Service | Description    | Qty | Rate            | Amount          |
| ------------------ | -------------- | --- | --------------- | --------------- |
| {Mapped Type}      | John Schneider | 1   | {payout amount} | {payout amount} |

Type mapping:

- "Consulting" → **Consulting**
- "Solution Partner Referral" → **Solution Partner Referral**
- "Originating" → **Originating Commission**
- "Closing" → **Closing Commission**

**Part 2: Op Fee**

| Product or Service          | Description                        | Qty               | Rate                   | Amount            |
| --------------------------- | ---------------------------------- | ----------------- | ---------------------- | ----------------- |
| Chameleon Collective Op Fee | {Op%}% of John Schneider's Revenue | -{Op% as decimal} | {John's section total} | {negative amount} |

Use "Revenue" in the description for Consulting, "Fees" for Solution Partner Referral.

**Part 3: Commissions from other sections** (if any)

For each commission John earns from another person's section:

| Product or Service     | Description                     | Qty | Rate     | Amount   |
| ---------------------- | ------------------------------- | --- | -------- | -------- |
| Originating Commission | {%}% of {Person's Name} Revenue | 1   | {amount} | {amount} |
| Closing Commission     | {%}% of {Person's Name} Revenue | 1   | {amount} | {amount} |

Use the actual commission percentage from the email (e.g., 5%, 7.5%) in the description.

When there are multiple other people, group their commissions together by person, in the order they appear in the email.

#### Line Items — Scenario B (Commission-only)

Only include lines for commissions John earns from other people's sections. No Op Fee.

| Product or Service     | Description                     | Qty | Rate     | Amount   |
| ---------------------- | ------------------------------- | --- | -------- | -------- |
| Originating Commission | {%}% of {Person's Name} Revenue | 1   | {amount} | {amount} |
| Closing Commission     | {%}% of {Person's Name} Revenue | 1   | {amount} | {amount} |

#### Note to Customer

Set the customer note/memo to the **client name** from the email header (e.g., "Orlando Health", "Radical Design", "Therapymatch Inc dba Headway"). If the client name is generic like "Goods & Services", use that.

---

## Worked Examples

### Example 1: Simple Consulting (Invoice 83162)

**Email**: Radical Design Co. — $975.00 | John's section only

- Consulting $877.50 (90%), Originating $48.75 (5%), Closing $48.75 (5%) | Total: $975.00

**Classification**: Scenario A — Consulting → 8% Op Fee

**Invoice lines:**

1. Consulting — John Schneider — 1 × $877.50 = $877.50
2. Originating Commission — John Schneider — 1 × $48.75 = $48.75
3. Closing Commission — John Schneider — 1 × $48.75 = $48.75
4. Chameleon Collective Op Fee — 8% of John Schneider's Revenue — -0.08 × $975.00 = −$78.00

**Note**: Radical Design | **Total: $897.00**

---

### Example 2: Consulting with Zero-Value Line Skipped (Invoice 83164)

**Email**: Goods & Services — $20,500.00 | John's section only

- Consulting $19,475.00 (95%), Chameleon Collective Inc Originating $0.00 (0%), Closing $1,025.00 (5%) | Total: $20,500.00

**Classification**: Scenario A — Consulting → 8% Op Fee

- Skip the $0 Originating line (recipient is Chameleon Collective Inc, not John)

**Invoice lines:**

1. Consulting — John Schneider — 1 × $19,475.00 = $19,475.00
2. Closing Commission — John Schneider — 1 × $1,025.00 = $1,025.00
3. Chameleon Collective Op Fee — 8% of John Schneider's Revenue — -0.08 × $20,500.00 = −$1,640.00

**Note**: Goods & Services | **Total: $18,860.00**

---

### Example 3: Consulting + Commissions from One Other Person (Invoice 83160)

**Email**: Therapymatch Inc dba Headway — $222.50

- **John's section**: Consulting $125.38 (85%), Originating $11.06 (7.5%), Closing $11.06 (7.5%) | Total: $147.50
- **Jeffrey Bibbs section**: Consulting $63.75 to Jeff, Originating $5.63 (7.5%) to John, Closing $5.63 (7.5%) to John | Total: $75.00

**Classification**: Scenario A — Consulting → 8% Op Fee on $147.50

**Invoice lines:**

1. Consulting — John Schneider — 1 × $125.38 = $125.38
2. Originating Commission — John Schneider — 1 × $11.06 = $11.06
3. Closing Commission — John Schneider — 1 × $11.06 = $11.06
4. Chameleon Collective Op Fee — 8% of John Schneider's Revenue — -0.08 × $147.50 = −$11.80
5. Closing Commission — 7.5% of Jeff Bibbs Revenue — 1 × $5.63 = $5.63
6. Originating Commission — 7.5% of Jeff Bibbs Revenue — 1 × $5.63 = $5.63

**Note**: Therapymatch Inc dba Headway | **Total: $146.96**

---

### Example 4: Consulting + Commissions from Two Other People (Invoice 83165)

**Email**: Orlando Health — $33,540.00

- **John's section**: Consulting $15,930.00 (90%), Originating $885.00 (5%), Closing $885.00 (5%) | Total: $17,700.00
- **Meegan Decker section**: Consulting $5,760 to Meegan, Originating $320.00 (5%) to John, Closing $320.00 (5%) to John | Total: $6,400.00
- **Jeffrey Bibbs section**: Consulting $8,496 to Jeff, Originating $472.00 (5%) to John, Closing $472.00 (5%) to John | Total: $9,440.00

**Classification**: Scenario A — Consulting → 8% Op Fee on $17,700.00

**Invoice lines:**

1. Consulting — John Schneider — 1 × $15,930.00 = $15,930.00
2. Originating Commission — John Schneider — 1 × $885.00 = $885.00
3. Closing Commission — John Schneider — 1 × $885.00 = $885.00
4. Chameleon Collective Op Fee — 8% of John Schneider's Revenue — -0.08 × $17,700.00 = −$1,416.00
5. Originating Commission — 5% of Meegan Decker Revenue — 1 × $320.00 = $320.00
6. Closing Commission — 5% of Meegan Decker Revenue — 1 × $320.00 = $320.00
7. Originating Commission — 5% of Jeff Bibbs Revenue — 1 × $472.00 = $472.00
8. Closing Commission — 5% of Jeff Bibbs Revenue — 1 × $472.00 = $472.00

**Note**: Orlando Health | **Total: $17,868.00**

---

### Example 5: Commission-Only Invoice (Invoice 83163)

**Email**: Radical Design Co. — $550.00

- **Radha Jujjavarapu section**: Consulting $495.00 to Radha, Originating $27.50 (5%) to John, Closing $27.50 (5%) to John | Total: $550.00

**Classification**: Scenario B — John has no primary section, commission-only. No Op Fee.

**Invoice lines:**

1. Originating Commission — 5% of Radha Jujjavarapu Revenue — 1 × $27.50 = $27.50
2. Closing Commission — 5% of Radha Jujjavarapu Revenue — 1 × $27.50 = $27.50

**Note**: Radical Design | **Total: $55.00**

---

### Example 6: Solution Partner Referral (Invoice 83081)

**Email**: Builder.io — $4,800.00 | John's section only

- Solution Partner Referral $4,080.00 (85%), Originating $360.00 (7.5%), Closing $360.00 (7.5%) | Total: $4,800.00

**Classification**: Scenario A — Solution Partner Referral → 20% Op Fee

**Invoice lines:**

1. Solution Partner Referral — John Schneider — 1 × $4,080.00 = $4,080.00
2. Originating Commission — John Schneider — 1 × $360.00 = $360.00
3. Closing Commission — John Schneider — 1 × $360.00 = $360.00
4. Chameleon Collective Op Fee — 20% of John Schneider Fees — -0.2 × $4,800.00 = −$960.00

**Total: $3,840.00**

---

## QuickBooks API Implementation Notes

### Invoice Creation

1. **Customer**: Look up or create "Chameleon Collective" as the customer
2. **Line items**: Use `SalesItemLineDetail` for each line
   - For the Op Fee line, use a negative quantity (e.g., -0.08 or -0.2) with the section total as the unit price
   - All other lines use Qty = 1
3. **Due date**: Calculate as invoice date + 30 days (Net 30)
4. **Invoice number**: Set `DocNumber` to match the Chameleon invoice number
5. **Customer memo**: Set `CustomerMemo` to the client name from the email

### Required Products/Services in QuickBooks

Ensure these items exist (create if missing):

- **Consulting** (Service, Income)
- **Solution Partner Referral** (Service, Income)
- **Originating Commission** (Service, Income)
- **Closing Commission** (Service, Income)
- **Chameleon Collective Op Fee** (Service, Income — used with negative quantities)

---

## Error Handling

- If the email format doesn't match the expected Collective OS structure, log a warning and skip
- If the invoice number already exists in QuickBooks, skip to avoid duplicates
- If John Schneider appears nowhere in the email as a recipient, skip — the invoice is not relevant to JHS Digital Consulting
- If the primary service type is unrecognized (not Consulting or Solution Partner Referral), default to 8% Op Fee and flag for manual review
- If a commission percentage cannot be parsed from the email, calculate it from the amount and section total, and flag for review

---

## Validation Checklist

Before submitting to QuickBooks:

1. **Op Fee base**: Op Fee is calculated ONLY on John's own section total, never on commissions from other sections
2. **Line item math**: Sum of all line items (positive minus Op Fee) equals the invoice total
3. **Commission completeness**: All of John's commissions from all other sections are included
4. **No duplicates**: Invoice number doesn't already exist in QuickBooks
5. **Zero-value exclusion**: No $0.00 line items appear on the invoice
6. **Non-John exclusion**: No line items for other people's consulting work (only John's payouts)

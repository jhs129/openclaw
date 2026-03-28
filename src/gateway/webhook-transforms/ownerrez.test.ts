import { describe, expect, test } from "vitest";
import { transformOwnerRezPayload } from "./ownerrez.js";

describe("transformOwnerRezPayload", () => {
  test("formats a booking insert with embedded entity", () => {
    const payload = {
      id: "wh-1",
      user_id: 12345,
      action: "entity_insert",
      entity_type: "booking",
      entity_id: "bk-100",
      categories: ["reservation"],
      entity: {
        arrival: "2026-03-15",
        departure: "2026-03-20",
        adults: 2,
        children: 1,
        status: "confirmed",
        guest_name: "Alice Smith",
        property_name: "Lakeside Cabin",
        total_amount: "1250.00",
        currency: "USD",
        source: "Airbnb",
        booked_utc: "2026-02-08T14:30:00Z",
      },
    };

    const result = transformOwnerRezPayload(payload);
    expect(result).not.toBeNull();
    expect(result!.name).toBe("OwnerRez");
    expect(result!.message).toContain("## OwnerRez: Booking Created");
    expect(result!.message).toContain("**Booking ID:** bk-100");
    expect(result!.message).toContain("**Guest:** Alice Smith");
    expect(result!.message).toContain("**Property:** Lakeside Cabin");
    expect(result!.message).toContain("**Dates:** 2026-03-15 to 2026-03-20");
    expect(result!.message).toContain("**Guests:** 2 adults, 1 child");
    expect(result!.message).toContain("**Status:** confirmed");
    expect(result!.message).toContain("**Total:** 1250.00 USD");
    expect(result!.message).toContain("**Source:** Airbnb");
    expect(result!.sessionKey).toBe("webhook:ownerrez:booking:bk-100");
  });

  test("formats a booking update without entity details", () => {
    const payload = {
      id: "wh-2",
      user_id: 12345,
      action: "entity_update",
      entity_type: "booking",
      entity_id: "bk-200",
      categories: ["cancellation"],
    };

    const result = transformOwnerRezPayload(payload);
    expect(result).not.toBeNull();
    expect(result!.message).toContain("## OwnerRez: Booking Updated");
    expect(result!.message).toContain("**Categories:** cancellation");
  });

  test("formats a booking delete", () => {
    const payload = {
      id: "wh-3",
      action: "entity_delete",
      entity_type: "booking",
      entity_id: "bk-300",
    };

    const result = transformOwnerRezPayload(payload);
    expect(result).not.toBeNull();
    expect(result!.message).toContain("## OwnerRez: Booking Deleted");
  });

  test("formats a contact insert with embedded entity", () => {
    const payload = {
      id: "wh-4",
      action: "entity_insert",
      entity_type: "contact",
      entity_id: "ct-50",
      entity: {
        first_name: "Bob",
        last_name: "Jones",
        email: "bob@example.com",
        phone: "+15551234567",
      },
    };

    const result = transformOwnerRezPayload(payload);
    expect(result).not.toBeNull();
    expect(result!.message).toContain("## OwnerRez: Contact Created");
    expect(result!.message).toContain("**Name:** Bob Jones");
    expect(result!.message).toContain("**Email:** bob@example.com");
    expect(result!.message).toContain("**Phone:** +15551234567");
    expect(result!.sessionKey).toBe("webhook:ownerrez:contact:ct-50");
  });

  test("handles authorization revoked", () => {
    const payload = {
      action: "application_authorization_revoked",
      user_id: 999,
    };

    const result = transformOwnerRezPayload(payload);
    expect(result).not.toBeNull();
    expect(result!.message).toContain("authorization has been revoked");
    expect(result!.sessionKey).toContain("auth-revoked");
  });

  test("handles property entity type", () => {
    const payload = {
      id: "wh-5",
      action: "entity_update",
      entity_type: "property",
      entity_id: "prop-10",
    };

    const result = transformOwnerRezPayload(payload);
    expect(result).not.toBeNull();
    expect(result!.message).toContain("## OwnerRez: Property Updated");
  });

  test("returns null for empty payload", () => {
    expect(transformOwnerRezPayload({})).toBeNull();
  });

  test("returns null for unknown action", () => {
    const payload = { action: "some_random_action" };
    expect(transformOwnerRezPayload(payload)).toBeNull();
  });

  test("returns null when entity_type is missing", () => {
    const payload = { action: "entity_insert" };
    expect(transformOwnerRezPayload(payload)).toBeNull();
  });

  test("includes guest_id, guest_email, guest_phone, property_id from top-level payload", () => {
    const payload = {
      id: "wh-7",
      action: "entity_update",
      entity_type: "booking",
      entity_id: "bk-500",
      guest_id: "g-42",
      guest_email: "alice@example.com",
      guest_phone: "+15559876543",
      property_id: "prop-99",
    };

    const result = transformOwnerRezPayload(payload);
    expect(result).not.toBeNull();
    expect(result!.message).toContain("**Guest ID:** g-42");
    expect(result!.message).toContain("**Guest Email:** alice@example.com");
    expect(result!.message).toContain("**Guest Phone:** +15559876543");
    expect(result!.message).toContain("**Property ID:** prop-99");
  });

  test("includes guest_id and property_id from embedded entity when not at top level", () => {
    const payload = {
      id: "wh-8",
      action: "entity_insert",
      entity_type: "booking",
      entity_id: "bk-600",
      entity: {
        guest_id: "g-77",
        email: "bob@example.com",
        phone: "+15551112222",
        property_id: "prop-55",
      },
    };

    const result = transformOwnerRezPayload(payload);
    expect(result).not.toBeNull();
    expect(result!.message).toContain("**Guest ID:** g-77");
    expect(result!.message).toContain("**Guest Email:** bob@example.com");
    expect(result!.message).toContain("**Guest Phone:** +15551112222");
    expect(result!.message).toContain("**Property ID:** prop-55");
  });

  test("omits identity fields when none are present", () => {
    const payload = {
      id: "wh-9",
      action: "entity_update",
      entity_type: "booking",
      entity_id: "bk-700",
    };

    const result = transformOwnerRezPayload(payload);
    expect(result).not.toBeNull();
    expect(result!.message).not.toContain("Guest ID");
    expect(result!.message).not.toContain("Guest Email");
    expect(result!.message).not.toContain("Guest Phone");
    expect(result!.message).not.toContain("Property ID");
  });

  test("always includes full raw payload as JSON code block", () => {
    const payload = {
      id: "wh-10",
      action: "entity_update",
      entity_type: "booking",
      entity_id: "bk-800",
      guest_id: "g-99",
      custom_field: "some-value",
    };

    const result = transformOwnerRezPayload(payload);
    expect(result).not.toBeNull();
    expect(result!.message).toContain("**Raw Payload:**");
    expect(result!.message).toContain("```json");
    expect(result!.message).toContain('"custom_field": "some-value"');
    expect(result!.message).toContain('"guest_id": "g-99"');
  });

  test("handles multiple children correctly in guest count", () => {
    const payload = {
      id: "wh-6",
      action: "entity_insert",
      entity_type: "booking",
      entity_id: "bk-400",
      entity: {
        adults: 1,
        children: 3,
      },
    };

    const result = transformOwnerRezPayload(payload);
    expect(result).not.toBeNull();
    expect(result!.message).toContain("1 adult");
    expect(result!.message).toContain("3 children");
  });
});

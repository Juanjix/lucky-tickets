export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  graphql_public: {
    Tables: {
      [_ in never]: never
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      graphql: {
        Args: {
          extensions?: Json
          operationName?: string
          query?: string
          variables?: Json
        }
        Returns: Json
      }
    }
    Enums: {
      [_ in never]: never
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
  public: {
    Tables: {
      audit_logs: {
        Row: {
          action: string
          actor_user_id: string | null
          created_at: string
          entity_id: string | null
          entity_type: string
          id: string
          metadata: Json
          organization_id: string | null
        }
        Insert: {
          action: string
          actor_user_id?: string | null
          created_at?: string
          entity_id?: string | null
          entity_type: string
          id?: string
          metadata?: Json
          organization_id?: string | null
        }
        Update: {
          action?: string
          actor_user_id?: string | null
          created_at?: string
          entity_id?: string | null
          entity_type?: string
          id?: string
          metadata?: Json
          organization_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "audit_logs_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      billing_accounts: {
        Row: {
          created_at: string
          fee_fixed_amount: number | null
          fee_percentage_bps: number | null
          fee_type: Database["public"]["Enums"]["fee_type"]
          id: string
          organization_id: string
          status: Database["public"]["Enums"]["organization_status"]
          updated_at: string
        }
        Insert: {
          created_at?: string
          fee_fixed_amount?: number | null
          fee_percentage_bps?: number | null
          fee_type: Database["public"]["Enums"]["fee_type"]
          id?: string
          organization_id: string
          status?: Database["public"]["Enums"]["organization_status"]
          updated_at?: string
        }
        Update: {
          created_at?: string
          fee_fixed_amount?: number | null
          fee_percentage_bps?: number | null
          fee_type?: Database["public"]["Enums"]["fee_type"]
          id?: string
          organization_id?: string
          status?: Database["public"]["Enums"]["organization_status"]
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "billing_accounts_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: true
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      check_ins: {
        Row: {
          checked_in_by: string | null
          created_at: string
          device_id: string | null
          event_id: string
          gate: string | null
          id: string
          organization_id: string
          ticket_id: string
        }
        Insert: {
          checked_in_by?: string | null
          created_at?: string
          device_id?: string | null
          event_id: string
          gate?: string | null
          id?: string
          organization_id: string
          ticket_id: string
        }
        Update: {
          checked_in_by?: string | null
          created_at?: string
          device_id?: string | null
          event_id?: string
          gate?: string | null
          id?: string
          organization_id?: string
          ticket_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "check_ins_org_event_fk"
            columns: ["organization_id", "event_id"]
            isOneToOne: false
            referencedRelation: "events"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "check_ins_org_ticket_fk"
            columns: ["organization_id", "ticket_id"]
            isOneToOne: false
            referencedRelation: "tickets"
            referencedColumns: ["organization_id", "id"]
          },
        ]
      }
      customers: {
        Row: {
          created_at: string
          email: string
          first_seen_at: string
          id: string
          last_seen_at: string
          marketing_consent: boolean
          marketing_consent_at: string | null
          name: string | null
          normalized_email: string | null
          organization_id: string
          phone: string | null
          updated_at: string
        }
        Insert: {
          created_at?: string
          email: string
          first_seen_at?: string
          id?: string
          last_seen_at?: string
          marketing_consent?: boolean
          marketing_consent_at?: string | null
          name?: string | null
          normalized_email?: string | null
          organization_id: string
          phone?: string | null
          updated_at?: string
        }
        Update: {
          created_at?: string
          email?: string
          first_seen_at?: string
          id?: string
          last_seen_at?: string
          marketing_consent?: boolean
          marketing_consent_at?: string | null
          name?: string | null
          normalized_email?: string | null
          organization_id?: string
          phone?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "customers_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      events: {
        Row: {
          capacity: number | null
          cover_image_url: string | null
          created_at: string
          description: string | null
          doors_open_at: string | null
          ends_at: string | null
          id: string
          name: string
          organization_id: string
          published_at: string | null
          sales_end_at: string | null
          sales_start_at: string | null
          slug: string
          starts_at: string
          status: Database["public"]["Enums"]["event_status"]
          updated_at: string
          venue_address: string | null
          venue_city: string | null
          venue_name: string | null
        }
        Insert: {
          capacity?: number | null
          cover_image_url?: string | null
          created_at?: string
          description?: string | null
          doors_open_at?: string | null
          ends_at?: string | null
          id?: string
          name: string
          organization_id: string
          published_at?: string | null
          sales_end_at?: string | null
          sales_start_at?: string | null
          slug: string
          starts_at: string
          status?: Database["public"]["Enums"]["event_status"]
          updated_at?: string
          venue_address?: string | null
          venue_city?: string | null
          venue_name?: string | null
        }
        Update: {
          capacity?: number | null
          cover_image_url?: string | null
          created_at?: string
          description?: string | null
          doors_open_at?: string | null
          ends_at?: string | null
          id?: string
          name?: string
          organization_id?: string
          published_at?: string | null
          sales_end_at?: string | null
          sales_start_at?: string | null
          slug?: string
          starts_at?: string
          status?: Database["public"]["Enums"]["event_status"]
          updated_at?: string
          venue_address?: string | null
          venue_city?: string | null
          venue_name?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "events_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      guest_lists: {
        Row: {
          created_at: string
          event_id: string
          id: string
          name: string
          organization_id: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          event_id: string
          id?: string
          name: string
          organization_id: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          event_id?: string
          id?: string
          name?: string
          organization_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "guest_lists_org_event_fk"
            columns: ["organization_id", "event_id"]
            isOneToOne: false
            referencedRelation: "events"
            referencedColumns: ["organization_id", "id"]
          },
        ]
      }
      guests: {
        Row: {
          checked_in_at: string | null
          created_at: string
          email: string | null
          event_id: string
          guest_list_id: string
          id: string
          name: string
          notes: string | null
          organization_id: string
          phone: string | null
          quantity: number
          status: Database["public"]["Enums"]["guest_status"]
          updated_at: string
        }
        Insert: {
          checked_in_at?: string | null
          created_at?: string
          email?: string | null
          event_id: string
          guest_list_id: string
          id?: string
          name: string
          notes?: string | null
          organization_id: string
          phone?: string | null
          quantity?: number
          status?: Database["public"]["Enums"]["guest_status"]
          updated_at?: string
        }
        Update: {
          checked_in_at?: string | null
          created_at?: string
          email?: string | null
          event_id?: string
          guest_list_id?: string
          id?: string
          name?: string
          notes?: string | null
          organization_id?: string
          phone?: string | null
          quantity?: number
          status?: Database["public"]["Enums"]["guest_status"]
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "guests_org_event_fk"
            columns: ["organization_id", "event_id"]
            isOneToOne: false
            referencedRelation: "events"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "guests_org_guest_list_fk"
            columns: ["organization_id", "guest_list_id"]
            isOneToOne: false
            referencedRelation: "guest_lists"
            referencedColumns: ["organization_id", "id"]
          },
        ]
      }
      order_items: {
        Row: {
          created_at: string
          id: string
          name_snapshot: string
          order_id: string
          organization_id: string
          quantity: number
          subtotal_amount: number
          ticket_type_id: string
          unit_price_amount: number
        }
        Insert: {
          created_at?: string
          id?: string
          name_snapshot: string
          order_id: string
          organization_id: string
          quantity: number
          subtotal_amount: number
          ticket_type_id: string
          unit_price_amount: number
        }
        Update: {
          created_at?: string
          id?: string
          name_snapshot?: string
          order_id?: string
          organization_id?: string
          quantity?: number
          subtotal_amount?: number
          ticket_type_id?: string
          unit_price_amount?: number
        }
        Relationships: [
          {
            foreignKeyName: "order_items_org_order_fk"
            columns: ["organization_id", "order_id"]
            isOneToOne: false
            referencedRelation: "orders"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "order_items_org_ticket_type_fk"
            columns: ["organization_id", "ticket_type_id"]
            isOneToOne: false
            referencedRelation: "ticket_types"
            referencedColumns: ["organization_id", "id"]
          },
        ]
      }
      orders: {
        Row: {
          buyer_email: string
          buyer_name: string
          buyer_phone: string | null
          checkout_token_hash: string | null
          created_at: string
          currency: string
          customer_id: string | null
          event_id: string
          expires_at: string | null
          id: string
          order_number: string
          organization_id: string
          paid_at: string | null
          provider_checkout_url: string | null
          provider_preference_id: string | null
          service_fee_amount: number
          status: Database["public"]["Enums"]["order_status"]
          subtotal_amount: number
          total_amount: number
          updated_at: string
        }
        Insert: {
          buyer_email: string
          buyer_name: string
          buyer_phone?: string | null
          checkout_token_hash?: string | null
          created_at?: string
          currency: string
          customer_id?: string | null
          event_id: string
          expires_at?: string | null
          id?: string
          order_number: string
          organization_id: string
          paid_at?: string | null
          provider_checkout_url?: string | null
          provider_preference_id?: string | null
          service_fee_amount?: number
          status?: Database["public"]["Enums"]["order_status"]
          subtotal_amount: number
          total_amount: number
          updated_at?: string
        }
        Update: {
          buyer_email?: string
          buyer_name?: string
          buyer_phone?: string | null
          checkout_token_hash?: string | null
          created_at?: string
          currency?: string
          customer_id?: string | null
          event_id?: string
          expires_at?: string | null
          id?: string
          order_number?: string
          organization_id?: string
          paid_at?: string | null
          provider_checkout_url?: string | null
          provider_preference_id?: string | null
          service_fee_amount?: number
          status?: Database["public"]["Enums"]["order_status"]
          subtotal_amount?: number
          total_amount?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "orders_org_customer_fk"
            columns: ["organization_id", "customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "orders_org_event_fk"
            columns: ["organization_id", "event_id"]
            isOneToOne: false
            referencedRelation: "events"
            referencedColumns: ["organization_id", "id"]
          },
        ]
      }
      organization_members: {
        Row: {
          created_at: string
          id: string
          organization_id: string
          role: Database["public"]["Enums"]["organization_role"]
          user_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          organization_id: string
          role?: Database["public"]["Enums"]["organization_role"]
          user_id: string
        }
        Update: {
          created_at?: string
          id?: string
          organization_id?: string
          role?: Database["public"]["Enums"]["organization_role"]
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "organization_members_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      organizations: {
        Row: {
          created_at: string
          currency: string
          id: string
          logo_url: string | null
          name: string
          slug: string
          status: Database["public"]["Enums"]["organization_status"]
          timezone: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          currency?: string
          id?: string
          logo_url?: string | null
          name: string
          slug: string
          status?: Database["public"]["Enums"]["organization_status"]
          timezone?: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          currency?: string
          id?: string
          logo_url?: string | null
          name?: string
          slug?: string
          status?: Database["public"]["Enums"]["organization_status"]
          timezone?: string
          updated_at?: string
        }
        Relationships: []
      }
      payment_accounts: {
        Row: {
          created_at: string
          id: string
          organization_id: string
          provider: Database["public"]["Enums"]["payment_provider"]
          provider_account_id: string
          status: Database["public"]["Enums"]["organization_status"]
          updated_at: string
        }
        Insert: {
          created_at?: string
          id?: string
          organization_id: string
          provider: Database["public"]["Enums"]["payment_provider"]
          provider_account_id: string
          status?: Database["public"]["Enums"]["organization_status"]
          updated_at?: string
        }
        Update: {
          created_at?: string
          id?: string
          organization_id?: string
          provider?: Database["public"]["Enums"]["payment_provider"]
          provider_account_id?: string
          status?: Database["public"]["Enums"]["organization_status"]
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "payment_accounts_organization_id_fkey"
            columns: ["organization_id"]
            isOneToOne: false
            referencedRelation: "organizations"
            referencedColumns: ["id"]
          },
        ]
      }
      payments: {
        Row: {
          approved_at: string | null
          created_at: string
          currency: string
          id: string
          order_id: string
          organization_id: string
          paid_amount: number
          payment_method: string | null
          provider: Database["public"]["Enums"]["payment_provider"]
          provider_order_id: string | null
          provider_payload: Json
          provider_payment_id: string
          status: Database["public"]["Enums"]["payment_status"]
          updated_at: string
        }
        Insert: {
          approved_at?: string | null
          created_at?: string
          currency: string
          id?: string
          order_id: string
          organization_id: string
          paid_amount: number
          payment_method?: string | null
          provider: Database["public"]["Enums"]["payment_provider"]
          provider_order_id?: string | null
          provider_payload?: Json
          provider_payment_id: string
          status?: Database["public"]["Enums"]["payment_status"]
          updated_at?: string
        }
        Update: {
          approved_at?: string | null
          created_at?: string
          currency?: string
          id?: string
          order_id?: string
          organization_id?: string
          paid_amount?: number
          payment_method?: string | null
          provider?: Database["public"]["Enums"]["payment_provider"]
          provider_order_id?: string | null
          provider_payload?: Json
          provider_payment_id?: string
          status?: Database["public"]["Enums"]["payment_status"]
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "payments_org_order_fk"
            columns: ["organization_id", "order_id"]
            isOneToOne: false
            referencedRelation: "orders"
            referencedColumns: ["organization_id", "id"]
          },
        ]
      }
      profiles: {
        Row: {
          avatar_url: string | null
          created_at: string
          display_name: string | null
          id: string
          updated_at: string
        }
        Insert: {
          avatar_url?: string | null
          created_at?: string
          display_name?: string | null
          id: string
          updated_at?: string
        }
        Update: {
          avatar_url?: string | null
          created_at?: string
          display_name?: string | null
          id?: string
          updated_at?: string
        }
        Relationships: []
      }
      settlement_items: {
        Row: {
          created_at: string
          description: string
          fee_amount: number
          gross_amount: number
          id: string
          net_amount: number
          organization_id: string
          quantity: number | null
          settlement_id: string
          ticket_type_id: string | null
        }
        Insert: {
          created_at?: string
          description: string
          fee_amount?: number
          gross_amount?: number
          id?: string
          net_amount?: number
          organization_id: string
          quantity?: number | null
          settlement_id: string
          ticket_type_id?: string | null
        }
        Update: {
          created_at?: string
          description?: string
          fee_amount?: number
          gross_amount?: number
          id?: string
          net_amount?: number
          organization_id?: string
          quantity?: number | null
          settlement_id?: string
          ticket_type_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "settlement_items_org_settlement_fk"
            columns: ["organization_id", "settlement_id"]
            isOneToOne: false
            referencedRelation: "settlements"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "settlement_items_org_ticket_type_fk"
            columns: ["organization_id", "ticket_type_id"]
            isOneToOne: false
            referencedRelation: "ticket_types"
            referencedColumns: ["organization_id", "id"]
          },
        ]
      }
      settlements: {
        Row: {
          created_at: string
          currency: string
          due_at: string | null
          event_id: string
          generated_at: string | null
          gross_sales_amount: number
          id: string
          organization_id: string
          paid_at: string | null
          platform_fee_amount: number
          status: Database["public"]["Enums"]["settlement_status"]
          tickets_sold: number
          updated_at: string
        }
        Insert: {
          created_at?: string
          currency: string
          due_at?: string | null
          event_id: string
          generated_at?: string | null
          gross_sales_amount?: number
          id?: string
          organization_id: string
          paid_at?: string | null
          platform_fee_amount?: number
          status?: Database["public"]["Enums"]["settlement_status"]
          tickets_sold?: number
          updated_at?: string
        }
        Update: {
          created_at?: string
          currency?: string
          due_at?: string | null
          event_id?: string
          generated_at?: string | null
          gross_sales_amount?: number
          id?: string
          organization_id?: string
          paid_at?: string | null
          platform_fee_amount?: number
          status?: Database["public"]["Enums"]["settlement_status"]
          tickets_sold?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "settlements_org_event_fk"
            columns: ["organization_id", "event_id"]
            isOneToOne: false
            referencedRelation: "events"
            referencedColumns: ["organization_id", "id"]
          },
        ]
      }
      ticket_holds: {
        Row: {
          created_at: string
          event_id: string
          expires_at: string
          id: string
          order_id: string | null
          organization_id: string
          quantity: number
          ticket_type_id: string
        }
        Insert: {
          created_at?: string
          event_id: string
          expires_at: string
          id?: string
          order_id?: string | null
          organization_id: string
          quantity: number
          ticket_type_id: string
        }
        Update: {
          created_at?: string
          event_id?: string
          expires_at?: string
          id?: string
          order_id?: string | null
          organization_id?: string
          quantity?: number
          ticket_type_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "ticket_holds_org_event_fk"
            columns: ["organization_id", "event_id"]
            isOneToOne: false
            referencedRelation: "events"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "ticket_holds_org_order_fk"
            columns: ["organization_id", "order_id"]
            isOneToOne: false
            referencedRelation: "orders"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "ticket_holds_org_ticket_type_fk"
            columns: ["organization_id", "ticket_type_id"]
            isOneToOne: false
            referencedRelation: "ticket_types"
            referencedColumns: ["organization_id", "id"]
          },
        ]
      }
      ticket_types: {
        Row: {
          active: boolean
          created_at: string
          currency: string
          description: string | null
          event_id: string
          id: string
          max_per_order: number
          name: string
          organization_id: string
          quantity: number
          sales_end_at: string | null
          sales_start_at: string | null
          sort_order: number
          unit_price_amount: number
          updated_at: string
          visibility: Database["public"]["Enums"]["ticket_visibility"]
        }
        Insert: {
          active?: boolean
          created_at?: string
          currency: string
          description?: string | null
          event_id: string
          id?: string
          max_per_order?: number
          name: string
          organization_id: string
          quantity: number
          sales_end_at?: string | null
          sales_start_at?: string | null
          sort_order?: number
          unit_price_amount: number
          updated_at?: string
          visibility?: Database["public"]["Enums"]["ticket_visibility"]
        }
        Update: {
          active?: boolean
          created_at?: string
          currency?: string
          description?: string | null
          event_id?: string
          id?: string
          max_per_order?: number
          name?: string
          organization_id?: string
          quantity?: number
          sales_end_at?: string | null
          sales_start_at?: string | null
          sort_order?: number
          unit_price_amount?: number
          updated_at?: string
          visibility?: Database["public"]["Enums"]["ticket_visibility"]
        }
        Relationships: [
          {
            foreignKeyName: "ticket_types_org_event_fk"
            columns: ["organization_id", "event_id"]
            isOneToOne: false
            referencedRelation: "events"
            referencedColumns: ["organization_id", "id"]
          },
        ]
      }
      tickets: {
        Row: {
          checked_in_at: string | null
          created_at: string
          event_id: string
          holder_email: string | null
          holder_name: string | null
          id: string
          issued_at: string | null
          order_id: string
          order_item_id: string
          organization_id: string
          qr_token_hash: string | null
          status: Database["public"]["Enums"]["ticket_status"]
          ticket_number: string
          ticket_type_id: string
          updated_at: string
        }
        Insert: {
          checked_in_at?: string | null
          created_at?: string
          event_id: string
          holder_email?: string | null
          holder_name?: string | null
          id?: string
          issued_at?: string | null
          order_id: string
          order_item_id: string
          organization_id: string
          qr_token_hash?: string | null
          status?: Database["public"]["Enums"]["ticket_status"]
          ticket_number: string
          ticket_type_id: string
          updated_at?: string
        }
        Update: {
          checked_in_at?: string | null
          created_at?: string
          event_id?: string
          holder_email?: string | null
          holder_name?: string | null
          id?: string
          issued_at?: string | null
          order_id?: string
          order_item_id?: string
          organization_id?: string
          qr_token_hash?: string | null
          status?: Database["public"]["Enums"]["ticket_status"]
          ticket_number?: string
          ticket_type_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "tickets_org_event_fk"
            columns: ["organization_id", "event_id"]
            isOneToOne: false
            referencedRelation: "events"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "tickets_org_order_fk"
            columns: ["organization_id", "order_id"]
            isOneToOne: false
            referencedRelation: "orders"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "tickets_org_order_item_fk"
            columns: ["organization_id", "order_item_id"]
            isOneToOne: false
            referencedRelation: "order_items"
            referencedColumns: ["organization_id", "id"]
          },
          {
            foreignKeyName: "tickets_org_ticket_type_fk"
            columns: ["organization_id", "ticket_type_id"]
            isOneToOne: false
            referencedRelation: "ticket_types"
            referencedColumns: ["organization_id", "id"]
          },
        ]
      }
      webhook_events: {
        Row: {
          error_message: string | null
          event_type: string
          id: string
          payload: Json
          processed_at: string | null
          provider: Database["public"]["Enums"]["payment_provider"]
          provider_event_id: string
          received_at: string
          status: Database["public"]["Enums"]["webhook_status"]
        }
        Insert: {
          error_message?: string | null
          event_type: string
          id?: string
          payload: Json
          processed_at?: string | null
          provider: Database["public"]["Enums"]["payment_provider"]
          provider_event_id: string
          received_at?: string
          status?: Database["public"]["Enums"]["webhook_status"]
        }
        Update: {
          error_message?: string | null
          event_type?: string
          id?: string
          payload?: Json
          processed_at?: string | null
          provider?: Database["public"]["Enums"]["payment_provider"]
          provider_event_id?: string
          received_at?: string
          status?: Database["public"]["Enums"]["webhook_status"]
        }
        Relationships: []
      }
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      check_event_ticket_capacity: {
        Args: { p_event_id: string }
        Returns: undefined
      }
      create_order_with_hold: {
        Args: {
          p_buyer_email: string
          p_buyer_name: string
          p_buyer_phone: string | null
          p_checkout_token_hash: string
          p_event_slug: string
          p_items: Json
          p_organization_slug: string
        }
        Returns: {
          currency: string
          expires_at: string
          items: Json
          order_id: string
          order_status: string
          subtotal_amount: number
          total_amount: number
        }[]
      }
      create_organization: {
        Args: { p_name: string; p_slug: string; p_timezone?: string }
        Returns: {
          created_at: string
          currency: string
          id: string
          logo_url: string | null
          name: string
          slug: string
          status: Database["public"]["Enums"]["organization_status"]
          timezone: string
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "organizations"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      expire_pending_orders: {
        Args: Record<PropertyKey, never>
        Returns: number
      }
      confirm_order_payment: {
        Args: {
          p_approved_at: string | null
          p_currency: string
          p_order_id: string
          p_paid_amount_minor: number
          p_payment_method: string | null
          p_provider: Database["public"]["Enums"]["payment_provider"]
          p_provider_payload: Json
          p_provider_payment_id: string
          p_status: Database["public"]["Enums"]["payment_status"]
          p_webhook_event_id: string | null
        }
        Returns: {
          order_id: string
          order_status: string
          outcome: string
          payment_id: string
        }[]
      }
      mark_webhook_event: {
        Args: {
          p_error_message: string | null
          p_status: Database["public"]["Enums"]["webhook_status"]
          p_webhook_event_id: string
        }
        Returns: undefined
      }
      record_payment_preference: {
        Args: {
          p_checkout_token_hash: string
          p_order_id: string
          p_provider: Database["public"]["Enums"]["payment_provider"]
          p_provider_checkout_url: string
          p_provider_preference_id: string
        }
        Returns: {
          order_id: string
          provider_checkout_url: string
          provider_preference_id: string
        }[]
      }
      record_webhook_event: {
        Args: {
          p_event_type: string
          p_payload: Json
          p_provider: Database["public"]["Enums"]["payment_provider"]
          p_provider_event_id: string
        }
        Returns: {
          already_existed: boolean
          status: Database["public"]["Enums"]["webhook_status"]
          webhook_event_id: string
        }[]
      }
      get_checkout_order: {
        Args: { p_checkout_token_hash: string; p_order_id: string }
        Returns: {
          currency: string
          event_name: string
          event_starts_at: string
          event_venue_name: string | null
          expires_at: string
          items: Json
          order_id: string
          order_status: string
          organization_id: string
          organization_name: string
          organization_timezone: string
          provider_checkout_url: string | null
          provider_preference_id: string | null
          subtotal_amount: number
          total_amount: number
        }[]
      }
      get_public_ticket_availability: {
        Args: { p_event_id: string }
        Returns: {
          is_sold_out: boolean
          ticket_type_id: string
        }[]
      }
      has_organization_role: {
        Args: {
          allowed_roles: Database["public"]["Enums"]["organization_role"][]
          target_organization_id: string
        }
        Returns: boolean
      }
      is_organization_member: {
        Args: { target_organization_id: string }
        Returns: boolean
      }
    }
    Enums: {
      event_status:
        | "DRAFT"
        | "PUBLISHED"
        | "FINISHED"
        | "CANCELLED"
        | "ARCHIVED"
      fee_type: "PERCENTAGE" | "FIXED_PER_TICKET" | "HYBRID" | "CUSTOM"
      guest_status: "INVITED" | "CHECKED_IN" | "CANCELLED"
      order_status:
        | "DRAFT"
        | "PENDING_PAYMENT"
        | "PAID"
        | "PAYMENT_FAILED"
        | "EXPIRED"
        | "CANCELLED"
        | "REFUNDED"
        | "PARTIALLY_REFUNDED"
      organization_role:
        | "OWNER"
        | "ADMIN"
        | "PRODUCER"
        | "DOOR_STAFF"
        | "VIEWER"
      organization_status: "ACTIVE" | "SUSPENDED" | "ARCHIVED"
      payment_provider: "MERCADO_PAGO"
      payment_status:
        | "PENDING"
        | "APPROVED"
        | "REJECTED"
        | "CANCELLED"
        | "REFUNDED"
        | "PARTIALLY_REFUNDED"
      settlement_status: "DRAFT" | "PENDING" | "PAID" | "OVERDUE" | "WAIVED"
      ticket_status: "VALID" | "CHECKED_IN" | "CANCELLED" | "REFUNDED"
      ticket_visibility: "PUBLIC" | "HIDDEN"
      webhook_status: "RECEIVED" | "PROCESSED" | "FAILED" | "IGNORED"
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends (DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never) = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends (PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never) = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  graphql_public: {
    Enums: {},
  },
  public: {
    Enums: {
      event_status: ["DRAFT", "PUBLISHED", "FINISHED", "CANCELLED", "ARCHIVED"],
      fee_type: ["PERCENTAGE", "FIXED_PER_TICKET", "HYBRID", "CUSTOM"],
      guest_status: ["INVITED", "CHECKED_IN", "CANCELLED"],
      order_status: [
        "DRAFT",
        "PENDING_PAYMENT",
        "PAID",
        "PAYMENT_FAILED",
        "EXPIRED",
        "CANCELLED",
        "REFUNDED",
        "PARTIALLY_REFUNDED",
      ],
      organization_role: ["OWNER", "ADMIN", "PRODUCER", "DOOR_STAFF", "VIEWER"],
      organization_status: ["ACTIVE", "SUSPENDED", "ARCHIVED"],
      payment_provider: ["MERCADO_PAGO"],
      payment_status: [
        "PENDING",
        "APPROVED",
        "REJECTED",
        "CANCELLED",
        "REFUNDED",
        "PARTIALLY_REFUNDED",
      ],
      settlement_status: ["DRAFT", "PENDING", "PAID", "OVERDUE", "WAIVED"],
      ticket_status: ["VALID", "CHECKED_IN", "CANCELLED", "REFUNDED"],
      ticket_visibility: ["PUBLIC", "HIDDEN"],
      webhook_status: ["RECEIVED", "PROCESSED", "FAILED", "IGNORED"],
    },
  },
} as const


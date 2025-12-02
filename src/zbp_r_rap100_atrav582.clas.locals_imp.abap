CLASS lhc_zr_rap100_atrav582 DEFINITION INHERITING FROM cl_abap_behavior_handler.
  PRIVATE SECTION.
    CONSTANTS:
      BEGIN OF travel_status,
        open      TYPE c LENGTH 1 VALUE 'O', "open
        accepted  TYPE c LENGTH 1 VALUE 'A', "accepted
        cancelled TYPE c LENGTH 1 VALUE 'X', "cancelled
      END OF travel_status.

    METHODS:
      get_global_authorizations FOR GLOBAL AUTHORIZATION
        IMPORTING
        REQUEST requested_authorizations FOR Travel
        RESULT result,

      earlynumbering_create FOR NUMBERING
        IMPORTING entities FOR CREATE Travel,

      setStatusOpen FOR DETERMINE ON MODIFY
        IMPORTING keys FOR Travel~setStatusOpen,

      validateCustomer FOR VALIDATE ON SAVE
        IMPORTING keys FOR Travel~validateCustomer,

      validateDates FOR VALIDATE ON SAVE
        IMPORTING keys FOR Travel~validateDates.
ENDCLASS.

CLASS lhc_zr_rap100_atrav582 IMPLEMENTATION.

  METHOD get_global_authorizations.
  ENDMETHOD.

  METHOD earlynumbering_create.

    " --- 1) Local variables: one holds a single entity, one holds the max travel id,
    "     and a flag to decide whether to use the number range mechanism.
    DATA:
      entity           TYPE STRUCTURE FOR CREATE zr_rap100_atrav582,
      travel_id_max    TYPE /dmo/travel_id,
      use_number_range TYPE abap_bool VALUE abap_false.

    " --- 2) Map entities that already contain a TravelID: these do not need numbering.
    "     We copy them into the mapped result so they pass through unchanged.
    LOOP AT entities INTO entity WHERE TravelID IS NOT INITIAL.
      APPEND CORRESPONDING #( entity ) TO mapped-Travel.
    ENDLOOP.

    " --- 3) Prepare a list with only entities that lack a TravelID.
    DATA(entities_wo_travelid) = entities.
    DELETE entities_wo_travelid WHERE TravelID IS NOT INITIAL.

    " --- 4) If configured to use number range service, request numbers for all entities
    "     without TravelID in a single call. Handle exceptions by reporting failures.
    IF use_number_range = abap_true.
      TRY.
          cl_numberrange_runtime=>number_get(
              EXPORTING
                nr_range_nr = '01'                                   " number range ID
                object = '/DMO/TRV_M'                                " object name for range
                quantity = CONV #( lines( entities_wo_travelid ) )   " how many numbers needed
                IMPORTING
                number = DATA(number_range_key)                      " returned number(s)
                returncode = DATA(number_range_return_code)
                returned_quantity = DATA(number_range_returned_quantity)
           ).
        CATCH cx_number_ranges INTO DATA(lx_number_ranges).
          " --- 4.a) On failure of number range service: mark each entity as failed and reported.
          LOOP AT entities_wo_travelid INTO entity.
            APPEND VALUE #( %cid = entity-%cid
                            %key = entity-%key
                            %is_draft = entity-%is_draft
                            %msg = lx_number_ranges )
                            TO reported-Travel.
            APPEND VALUE #( %cid = entity-%cid
                            %key = entity-%key
                            %is_draft = entity-%is_draft )
                            TO failed-Travel.
          ENDLOOP.
          " --- 4.b) Exit the method after reporting failures from number range call.
          EXIT.
      ENDTRY.

    ELSE.
      " --- 5) If not using number range, compute the max TravelID from the DB table.
      "     Consider both persisted and draft records to avoid duplicates.
      SELECT SINGLE FROM zrap100_atrav582 FIELDS MAX( travel_id ) AS travelID INTO @travel_id_max.
      SELECT SINGLE FROM zrap100_atrav582 FIELDS MAX( travel_id ) INTO @DATA(max_travelid_draft).
      IF max_travelid_draft > travel_id_max.
        travel_id_max = max_travelid_draft.
      ENDIF.
    ENDIF.

    " --- 6) Assign incremental TravelID values to each entity that lacked one,
    "     incrementing the computed max value for each entity and mapping them for creation.
    LOOP AT entities_wo_travelid INTO entity.
      travel_id_max += 1.
      entity-TravelID = travel_id_max.

      APPEND VALUE #( %cid = entity-%cid
                      %key = entity-%key
                      %is_draft = entity-%is_draft
                      ) TO mapped-Travel.
    ENDLOOP.

  ENDMETHOD.

  METHOD setStatusOpen.

    READ ENTITIES OF zr_rap100_atrav582 IN LOCAL MODE
    ENTITY Travel
    FIELDS ( OverallStatus )
    WITH CORRESPONDING #( keys )
    RESULT DATA(travels)
    FAILED DATA(read_failed).

    DELETE travels WHERE OverallStatus IS NOT INITIAL.
    CHECK travels IS NOT INITIAL.

    MODIFY ENTITIES OF zr_rap100_atrav582 IN LOCAL MODE
    ENTITY Travel
    UPDATE SET FIELDS
    WITH VALUE #( FOR Travel IN travels ( %tky      = Travel-%tky
                                          overallstatus = travel_status-open ) )
                                          REPORTED DATA(update_reported).
    reported = CORRESPONDING #( DEEP update_reported ).

  ENDMETHOD.

  METHOD validateCustomer.

    READ ENTITIES OF zr_rap100_atrav582 IN LOCAL MODE
    ENTITY Travel
    FIELDS ( CustomerID )
    WITH CORRESPONDING #( keys )
    RESULT DATA(travels).

    DATA customers TYPE SORTED TABLE OF /dmo/customer WITH UNIQUE KEY customer_id.

    customers = CORRESPONDING #( travels DISCARDING DUPLICATES MAPPING customer_id = customerID EXCEPT * ).
    DELETE customers WHERE customer_id IS INITIAL.
    IF customers IS NOT INITIAL.
      SELECT FROM /dmo/customer FIELDS customer_id
          FOR ALL ENTRIES IN @customers
          WHERE customer_id = @customers-customer_id
          INTO TABLE @DATA(valid_customers).
    ENDIF.

    LOOP AT travels INTO DATA(travel).
      APPEND VALUE #( %tky = travel-%tky
                      %state_area = 'VALIDATE_CUSTOMER'
                    ) TO reported-travel.

      IF travel-CustomerID IS INITIAL.
        APPEND VALUE #( %tky = travel-%tky ) TO failed-travel.

        APPEND VALUE #( %tky = travel-%tky
                        %state_area = 'VALIDATE_CUSTOMER'
                        %msg = NEW /dmo/cm_flight_messages(
                                textid = /dmo/cm_flight_messages=>enter_customer_id
                                severity = if_abap_behv_message=>severity-error )
                        %element-CustomerID = if_abap_behv=>mk-on
        ) TO reported-travel.

      ELSEIF travel-CustomerID IS NOT INITIAL AND NOT line_exists( valid_customers[ customer_id = travel-CustomerID ] ).
        APPEND VALUE #( %tky = travel-%tky ) TO failed-travel.

        APPEND VALUE #( %tky = travel-%tky
                        %state_area = 'VALIDATE_CUSTOMER'
                        %msg = NEW /dmo/cm_flight_messages(
                                textid = /dmo/cm_flight_messages=>customer_unkown
                                severity = if_abap_behv_message=>severity-error
                                customer_id = travel-CustomerID )
                        %element-CustomerID = if_abap_behv=>mk-on
                        ) TO reported-travel.
      ENDIF.

    ENDLOOP.

  ENDMETHOD.

  METHOD validateDates.

    READ ENTITIES OF zr_rap100_atrav582 IN LOCAL MODE
    ENTITY Travel
    FIELDS ( BeginDate EndDate TravelID )
    WITH CORRESPONDING #( keys )
    RESULT DATA(travels).

    LOOP AT travels INTO DATA(travel).
      APPEND VALUE #( %tky = travel-%tky
      %state_area = 'VALIDATE_DATES'
      ) TO reported-travel.

      IF travel-BeginDate IS INITIAL.
        APPEND VALUE #( %tky = travel-%tky ) TO failed-travel.

        APPEND VALUE #( %tky = travel-%tky
                        %state_area = 'VALIDATE_DATES'
                        %msg = NEW /dmo/cm_flight_messages( begin_date = travel-BeginDate
                                                            textid = /dmo/cm_flight_messages=>begin_date_on_or_bef_sysdate
                                                            severity = if_abap_behv_message=>severity-error )
                        %element-BeginDate = if_abap_behv=>mk-on ) TO reported-travel.
      ENDIF.

      IF travel-EndDate IS INITIAL.
        APPEND VALUE #( %tky = travel-%tky ) TO failed-travel.

        APPEND VALUE #( %tky               = travel-%tky
                        %state_area        = 'VALIDATE_DATES'
                         %msg                = NEW /dmo/cm_flight_messages(
                                                                textid   = /dmo/cm_flight_messages=>enter_end_date
                                                               severity = if_abap_behv_message=>severity-error )
                        %element-EndDate   = if_abap_behv=>mk-on ) TO reported-travel.
      ENDIF.
      IF travel-EndDate < travel-BeginDate AND travel-BeginDate IS NOT INITIAL
                                           AND travel-EndDate IS NOT INITIAL.
        APPEND VALUE #( %tky = travel-%tky ) TO failed-travel.

        APPEND VALUE #( %tky               = travel-%tky
                        %state_area        = 'VALIDATE_DATES'
                        %msg               = NEW /dmo/cm_flight_messages(
                                                                textid     = /dmo/cm_flight_messages=>begin_date_bef_end_date
                                                                begin_date = travel-BeginDate
                                                                end_date   = travel-EndDate
                                                                severity   = if_abap_behv_message=>severity-error )
                        %element-BeginDate = if_abap_behv=>mk-on
                        %element-EndDate   = if_abap_behv=>mk-on ) TO reported-travel.
      ENDIF.
    ENDLOOP.
  ENDMETHOD.

ENDCLASS.

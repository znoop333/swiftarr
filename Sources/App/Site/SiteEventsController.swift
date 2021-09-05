import Vapor
import Crypto
import FluentSQL

struct SiteEventsController: SiteControllerUtils {

	func registerRoutes(_ app: Application) throws {
		// Routes that the user does not need to be logged in to access.
		let openRoutes = getOpenRoutes(app)
        openRoutes.get("events", use: eventsPageHandler)
        openRoutes.get("events", eventIDParam, "calendarevent", use: eventsDownloadICSHandler)

		// Routes for non-shareable content. If you're not logged in we failscreen.
		let privateRoutes = getPrivateRoutes(app)
        privateRoutes.post("events", eventIDParam, "favorite", use: eventsAddRemoveFavoriteHandler)
        privateRoutes.delete("events", eventIDParam, "favorite", use: eventsAddRemoveFavoriteHandler)
	}
	
// MARK: - Events
	/// Shows a day's worth events. Always attempts to show events from a day on the actual cruise. Uses `Settings.shared.cruiseStartDate`
	/// for cruise dates; the ingested schedule should have events for that day and the next 7 days.
	/// 
	/// Use the 'day' or 'cruiseday' query parameter to request which day to show. If no parameter given, uses the current day of week.
	///
	/// Query Parameters:
	/// - day=STRING			One of: "sun" ... "sat". Can also use "1sat" for first Saturday (embarkation day), or "2sat" for the next Saturday.
	/// - cruiseday=INT		Generally 1...8, where 1 is embarkation day.
    func eventsPageHandler(_ req: Request) throws -> EventLoopFuture<View> {
    	var queryString: String
    	var dayOfCruise: Int
    	if let weekdayParam = req.query[String.self, at: "day"] {
    		queryString = "day=\(weekdayParam)"
    		var dayOfWeek: Int
			switch weekdayParam {
			case "sun": dayOfWeek = 1
			case "mon": dayOfWeek = 2
			case "tue": dayOfWeek = 3
			case "wed": dayOfWeek = 4
			case "thu": dayOfWeek = 5
			case "fri": dayOfWeek = 6
			case "sat": dayOfWeek = 7
			default: dayOfWeek = 7
			}
			dayOfCruise = (7 + dayOfWeek - Settings.shared.cruiseStartDayOfWeek) % 7 + 1
		}
    	else if let cruisedayParam = req.query[Int.self, at: "cruiseday"] {
    		queryString = "cruiseday=\(cruisedayParam)"
    		dayOfCruise = cruisedayParam
		}		
		else {
			let thisWeekday = Calendar.autoupdatingCurrent.component(.weekday, from: Date())
			dayOfCruise = (7 + thisWeekday - Settings.shared.cruiseStartDayOfWeek) % 7 + 1
    		queryString = "cruiseday=\(dayOfCruise)"
		}
		return apiQuery(req, endpoint: "/events?\(queryString)", passThroughQuery: false).throwingFlatMap { response in
 			let events = try response.content.decode([EventData].self)
     		struct EventPageContext : Encodable {
     			struct CruiseDay : Encodable {
     				var name: String
     				var index: Int
     				var activeDay: Bool
     			}
				var trunk: TrunkContext
    			var events: [EventData]
    			var day: Int
    			var days: [CruiseDay]
    			var isBeforeCruise: Bool
    			var isAfterCruise: Bool
    			var upcomingEvent: EventData?
    			
    			init(_ req: Request, events: [EventData], dayOfCruise: Int) {
    				self.events = events
    				trunk = .init(req, title: "Events", tab: .events)
    				self.day = dayOfCruise
    				isBeforeCruise = Date() < Settings.shared.cruiseStartDate
    				isAfterCruise = Date() > Calendar.autoupdatingCurrent.date(byAdding: .day, value: Settings.shared.cruiseLengthInDays, 
    						to: Settings.shared.cruiseStartDate) ?? Date()
    				
    				// Set up the day buttons, one for each day of the cruise.		
					let daynames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    				days = Array<CruiseDay>()
    				for dayIndex in 1...Settings.shared.cruiseLengthInDays {
    					let weekday = (Settings.shared.cruiseStartDayOfWeek + dayIndex - 2) % 7
    					days.append(CruiseDay(name: daynames[weekday], index: dayIndex, activeDay: dayIndex == dayOfCruise))
    				}
    				
    				if let _ = trunk.alertCounts.nextFollowedEventTime {
    					let secondsPerWeek = 60 * 60 * 24 * 7
    					let partialWeek = Int(Date().timeIntervalSince(Settings.shared.cruiseStartDate)) % secondsPerWeek
    					let dateInCruiseWeek = Settings.shared.cruiseStartDate + TimeInterval(partialWeek)
						upcomingEvent = events.first {
							return $0.isFavorite 
							// && ((-5 * 60)...(15 * 60)).contains(dateInCruiseWeek.timeIntervalSince($0.startTime))
						}
					}
    			}
    		}
    		let eventContext = EventPageContext(req, events: events, dayOfCruise: dayOfCruise)
			return req.view.render("events", eventContext)
    	}
    }
    
    func eventsDownloadICSHandler(_ req: Request) throws -> EventLoopFuture<Response> {
    	guard let eventID = req.parameters.get(eventIDParam.paramString) else {
            throw Abort(.badRequest, reason: "Missing event ID parameter.")
    	}
		return apiQuery(req, endpoint: "/events/\(eventID)").throwingFlatMap { response in
 			let event = try response.content.decode(EventData.self)
			let icsString = buildEventICS(event: event)
			let headers = HTTPHeaders([("Content-Disposition", "attachment; filename=\(event.title).ics")])
			return icsString.encodeResponse(status: .ok, headers: headers, for: req)
		}
    }

	// Glue code that calls the API to favorite/unfavorite an event. Returns 201/204 on success.
    func eventsAddRemoveFavoriteHandler(_ req: Request) throws -> EventLoopFuture<HTTPStatus> {
    	guard let eventID = req.parameters.get(eventIDParam.paramString) else {
            throw Abort(.badRequest, reason: "Missing event ID parameter.")
    	}
    	return apiQuery(req, endpoint: "/events/\(eventID)/favorite", method: req.method).map { response in
    		return response.status
    	}
    }
    
// MARK: - Utility fns

	/// Creates a iCalendar data file describing the given event. iCalendar is also known as VCALENDAR or an .ics file.
	/// It's the thing most calendar event importers have standardized on for data interchange.
	func buildEventICS(event: EventData) -> String {
		let dateFormatter = ISO8601DateFormatter()
		dateFormatter.formatOptions = [ .withYear, .withMonth, .withDay, .withTime, .withTimeZone ]
		let startTime = dateFormatter.string(from: event.startTime)
		let endTime = dateFormatter.string(from: event.endTime)
		let stampTime = dateFormatter.string(from: Date())				// DTSTAMP is when the ICS was created, which is now.
		let eventICSTemplate = """
				BEGIN:VCALENDAR
				VERSION:2.0
				X-WR-CALNAME:jococruise2022
				X-WR-CALDESC:Event Calendar
				METHOD:PUBLISH
				CALSCALE:GREGORIAN
				PRODID:-//Sched.com JoCo Cruise 2022//EN
				X-WR-TIMEZONE:UTC
				BEGIN:VEVENT
				DTSTAMP:\(stampTime)
				DTSTART:\(startTime)
				DTEND:\(endTime)
				SUMMARY:\(icsEscapeString(event.title))
				DESCRIPTION:\(icsEscapeString(event.description))
				CATEGORIES:\(icsEscapeString(event.eventType))
				LOCATION:\(icsEscapeString(event.location))
				SEQUENCE:0
				UID:\(icsEscapeString(event.uid))
				END:VEVENT
				END:VCALENDAR
				"""
		return eventICSTemplate
	}
	
	// the ICS file format has specific string escaping requirements. See https://datatracker.ietf.org/doc/html/rfc5545
	func icsEscapeString(_ str: String) -> String {
		let result = str.replacingOccurrences(of: "\\", with: "\\\\")
				.replacingOccurrences(of: ";", with: "\\;")
				.replacingOccurrences(of: ",", with: "\\,")
				.replacingOccurrences(of: "\n", with: "\\n")
		return result
	}

}
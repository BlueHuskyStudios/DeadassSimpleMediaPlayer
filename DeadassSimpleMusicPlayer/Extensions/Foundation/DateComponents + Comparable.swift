//
//  DateComponents + Comparable.swift
//  DeadassSimpleMusicPlayer
//
//  Created by Ky on 2026-08-04.
//

import Foundation



extension DateComponents: @retroactive Comparable {
    
    /// Compares the individual components of the given two values to find which occurs before the other.
    ///
    /// If they both have non-nil `.date` fields, those are compared and the result sent back unconditionally. Otherwise, each component is compared, starting at the most-significant and working down to the least-significant until a difference is found.
    ///
    /// - Attention: The two dates _must_ share the same calendar. Attempting to compare two `DateComponent` values across two different calendars will result in this function _always_ returning `false`.
    ///
    /// - Returns: `true` iff `lhs` definitely comes before `rhs`, `false` otherwise.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if let lhs_date = lhs.date,
           let rhs_date = rhs.date
        {
            return lhs_date < rhs_date
        }
        
        guard lhs.calendar == rhs.calendar else { return false }
        
        return if let lhs_era = lhs.era,               let rhs_era = rhs.era,               lhs_era != rhs_era               { lhs_era        < rhs_era        }
          else if let lhs_year = lhs.year,             let rhs_year = rhs.year,             lhs_year != rhs_year             { lhs_year       < rhs_year       }
          else if let lhs_month = lhs.month,           let rhs_month = rhs.month,           lhs_month != rhs_month           { lhs_month      < rhs_month      }
          else if let lhs_day = lhs.day,               let rhs_day = rhs.day,               lhs_day != rhs_day               { lhs_day        < rhs_day        }
          else if let lhs_weekOfYear = lhs.weekOfYear, let rhs_weekOfYear = rhs.weekOfYear, lhs_weekOfYear != rhs_weekOfYear { lhs_weekOfYear < rhs_weekOfYear }
          else if let lhs_hour = lhs.hour,             let rhs_hour = rhs.hour,             lhs_hour != rhs_hour             { lhs_hour       < rhs_hour       }
          else if let lhs_minute = lhs.minute,         let rhs_minute = rhs.minute,         lhs_minute != rhs_minute         { lhs_minute     < rhs_minute     }
          else if let lhs_second = lhs.second,         let rhs_second = rhs.second,         lhs_second != rhs_second         { lhs_second     < rhs_second     }
          else if let lhs_nanosecond = lhs.nanosecond, let rhs_nanosecond = rhs.nanosecond, lhs_nanosecond != rhs_nanosecond { lhs_nanosecond < rhs_nanosecond }
          else                                                                                                               { false }
    }
}
